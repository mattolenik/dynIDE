defmodule HerdrServer.Client.RemoteHandoffTest.Hold do
  @moduledoc false
  # records the conns' HOLD/UPDATE/DROP (config :herdr_server, :client_hold)
  def hold(key, blob, fds), do: report({:hold, key, blob, length(fds)})
  def update(key, blob), do: report({:update, key, blob})
  def drop(key), do: report({:drop, key})

  defp report(msg) do
    if pid = Application.get_env(:herdr_server, :client_hold_test), do: send(pid, msg)
    :ok
  end
end

defmodule HerdrServer.Client.RemoteHandoffTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import HerdrServer.Test.WireClient

  alias HerdrScene.{Event, Protocol, Wire}
  alias HerdrServer.Client.Remote
  alias HerdrServer.Handoff.Link
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Native.Link, as: NLink
  alias HerdrServer.Pane.Rows

  setup do
    Application.put_env(:herdr_server, :client_hold, __MODULE__.Hold)
    Application.put_env(:herdr_server, :client_hold_test, self())

    on_exit(fn ->
      Application.delete_env(:herdr_server, :client_hold)
      Application.delete_env(:herdr_server, :client_hold_test)
      :persistent_term.erase(Protocol.handoff_key())
      if pid = GenServer.whereis(Link), do: GenServer.stop(pid)
    end)
  end

  defp typed(id) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    Fake.Pty.writes(pty) |> Enum.join()
  end

  defp conn(id) do
    [{pid, _}] = Registry.lookup(Remote.Registry, id)
    pid
  end

  defp wait_until(fun, n \\ 300) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, n - 1)
    end
  end

  defp blob(b), do: :erlang.binary_to_term(b)

  defp attached!(s, resumed) do
    assert {:attached, %{resumed: ^resumed}} = recv_frame(s)
    recv_until(s, &match?({:scene, _}, &1))
    s
  end

  # a connected pair whose server end exists only as the returned fd resource
  defp socket_pair do
    path = Path.join(System.tmp_dir!(), "hlh#{System.unique_integer([:positive])}.sock")
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    on_exit(fn -> File.rm(path) end)
    {:ok, c} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 5000)
    {:ok, a} = :gen_tcp.accept(l, 5000)
    {:ok, n} = :inet.getfd(a)
    {:ok, fd} = NLink.fd_dup(n)
    :ok = :gen_tcp.close(a)
    :ok = :gen_tcp.close(l)
    {c, fd}
  end

  test "attach holds client/<id>" do
    ctx = setup_listener()
    attached!(attach(ctx, client_id: "held1"), false)
    assert_receive {:hold, "client/held1", b, 1}, 2000
    assert %{v: 1, client_id: "held1", acked: -1, buffer: "", info: %{kind: :term}} = blob(b)
  end

  test "prepare freezes: nothing written after prepare, partial input carried" do
    ctx = setup_listener()
    s = attached!(attach(ctx, client_id: "frz"), false)
    frame = Wire.encode({:input, 1, Event.key("q")})
    {head, tail} = :erlang.split_binary(IO.iodata_to_binary(frame), 6)
    :ok = :gen_tcp.send(s, head)
    wait_until(fn -> :sys.get_state(conn("frz")).buf == head end)

    :ok = Remote.prepare_all()
    assert_receive {:update, "client/frz", b}, 2000
    assert %{buffer: ^head, acked: -1} = blob(b)

    # neither read nor written while frozen
    :ok = :gen_tcp.send(s, tail)
    send(conn("frz"), {:notice, %{level: :info, text: "held"}})
    assert {:error, :timeout} = recv_frame(s, 300)
    assert typed(1) == ""

    :ok = Remote.thaw_all()
    assert {:notice, %{text: "held"}} = recv_until(s, &match?({:notice, _}, &1))
    assert {:ack, 1} = recv_until(s, &match?({:ack, _}, &1))
    assert typed(1) == "q"
  end

  test "adopted entry resumes the same socket" do
    {c, fd} = socket_pair()
    info = attach_info(client_id: "abc")
    # a whole frame and half of the next were read by the old VM
    carried = IO.iodata_to_binary(Wire.encode({:input, 4, Event.key("x")}))
    next = IO.iodata_to_binary(Wire.encode({:input, 5, Event.key("y")}))
    {head, tail} = :erlang.split_binary(next, 5)

    b =
      :erlang.term_to_binary(%{
        v: 1,
        client_id: "abc",
        info: info,
        acked: 3,
        buffer: carried <> head
      })

    :ok = Link.put_adopted_for_test([{"client/abc", b, [fd]}])
    _ctx = setup_listener()

    assert {:attached, %{resumed: :handoff}} = recv_frame(c)
    assert {:scene, _} = recv_until(c, &match?({:scene, _}, &1))
    assert_receive {:update, "client/abc", b2}, 2000
    assert %{buffer: "", acked: 3} = blob(b2)

    :ok = :gen_tcp.send(c, tail)
    # resent after the handoff: 3 is acked already (re-acked, not applied), 4 was carried
    :ok = send_frame(c, {:input, 3, Event.key("z")})
    :ok = send_frame(c, {:input, 6, Event.key("w")})
    assert {:ack, 6} = recv_until(c, &match?({:ack, 6}, &1))
    assert typed(1) == "xyw"
    assert Link.take_adopted("client/") == []

    # the adopted socket's fd is ours: a server-side close reaches the client
    :ok = send_frame(c, {:detach})
    assert_receive {:drop, "client/abc"}, 2000
    assert :closed = recv_closed(c)
  end

  test "bad blob is unclaimed and the fd closed" do
    {c, fd} = socket_pair()
    :ok = Link.put_adopted_for_test([{"client/bad", "not a term", [fd]}])
    _ctx = setup_listener()
    assert :closed = recv_closed(c)
    assert :sys.get_state(Link).rejected == ["client/bad"]
  end

  test "detach drops the hold" do
    ctx = setup_listener()
    s = attached!(attach(ctx, client_id: "det1"), false)
    assert_receive {:hold, "client/det1", _, 1}, 2000
    :ok = send_frame(s, {:detach})
    assert {:detached, _} = recv_until(s, &match?({:detached, _}, &1))
    assert_receive {:drop, "client/det1"}, 2000
    assert :closed = recv_closed(s)
  end

  test "a lost socket drops the hold" do
    ctx = setup_listener()
    s = attached!(attach(ctx, client_id: "lost1"), false)
    assert_receive {:hold, "client/lost1", _, 1}, 2000
    :gen_tcp.close(s)
    assert_receive {:drop, "client/lost1"}, 2000
  end

  test "no conn starts during a handoff" do
    ctx = setup_listener()
    :persistent_term.put(Protocol.handoff_key(), :begin)
    s = attach(ctx, client_id: "late1")
    assert :closed = recv_closed(s)
    assert Registry.lookup(Remote.Registry, "late1") == []
  end
end
