defmodule DynideServer.Client.RemoteHandoffTest.Hold do
  @moduledoc false
  # records the conns' HOLD/UPDATE/DROP (config :dynide_server, :client_hold)
  def hold(key, blob, fds), do: report({:hold, key, blob, length(fds)})
  def update(key, blob), do: report({:update, key, blob})
  def drop(key), do: report({:drop, key})

  defp report(msg) do
    if pid = Application.get_env(:dynide_server, :client_hold_test), do: send(pid, msg)
    :ok
  end
end

defmodule DynideServer.Client.RemoteHandoffTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import DynideServer.Test.WireClient

  alias DynideScene.{Event, Protocol, Wire}
  alias DynideServer.Client.{Remote, Socket}
  alias DynideServer.Handoff.Link
  alias DynideServer.Kernel.Fake
  alias DynideServer.Native.Link, as: NLink
  alias DynideServer.Pane.Rows

  setup do
    Application.put_env(:dynide_server, :client_hold, __MODULE__.Hold)
    Application.put_env(:dynide_server, :client_hold_test, self())

    on_exit(fn ->
      Application.delete_env(:dynide_server, :client_hold)
      Application.delete_env(:dynide_server, :client_hold_test)
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
    path =
      Path.join(
        System.tmp_dir!(),
        "hlh#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

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

  defp carried_blob(id, info, opts) do
    :erlang.term_to_binary(
      Map.merge(
        %{v: 1, client_id: id, info: info, acked: -1, buffer: "", prepared: true},
        Map.new(opts)
      )
    )
  end

  # a blob the adopting VM must not carry: the client sees EOF, reconnects and resumes
  defp grace_resume!(id, opts) do
    {c, fd} = socket_pair()
    b = carried_blob(id, attach_info(client_id: id), opts)
    :ok = Link.put_adopted_for_test([{"client/" <> id, b, [fd]}])
    ctx = setup_listener()
    :ok = Remote.Supervisor.adopt_all()
    assert :closed = recv_closed(c)
    assert :sys.get_state(Link).rejected == ["client/" <> id]
    attached!(attach(ctx, client_id: id), true)
  end

  test "a blob not prepared for this handoff resumes in grace" do
    grace_resume!("crashed", prepared: false)
  end

  test "a carried buffer over 1 MiB resumes in grace" do
    grace_resume!("bigbuf", buffer: :binary.copy("x", 1_048_577))
  end

  test "an adopted entry whose attach fails is unclaimed and closed" do
    ctx = setup_listener()
    attached!(attach(ctx, client_id: "twice"), false)
    {c, fd} = socket_pair()
    b = carried_blob("twice", attach_info(client_id: "twice"), [])
    :ok = Link.put_adopted_for_test([{"client/twice", b, [fd]}])
    # the id is taken: registering the adopted conn fails
    assert :ignore = Remote.Supervisor.start_adopted(hd(Link.take_adopted("client/")))
    assert :closed = recv_closed(c)
    assert :sys.get_state(Link).rejected == ["client/twice"]
  end

  test "a crashed or stopped conn drops its hold" do
    ctx = setup_listener()
    attached!(attach(ctx, client_id: "crash1"), false)
    assert_receive {:hold, "client/crash1", _, 1}, 2000
    catch_exit(GenServer.call(conn("crash1"), :no_such_call))
    assert_receive {:drop, "client/crash1"}, 2000

    attached!(attach(ctx, client_id: "stop1"), false)
    assert_receive {:hold, "client/stop1", _, 1}, 2000
    :ok = DynamicSupervisor.terminate_child(Remote.Supervisor, conn("stop1"))
    assert_receive {:drop, "client/stop1"}, 2000
  end

  test "a conn that does not answer prepare is dropped, and held again at thaw" do
    ctx = setup_listener()
    attached!(attach(ctx, client_id: "slow1"), false)
    assert_receive {:hold, "client/slow1", _, 1}, 2000
    pid = conn("slow1")
    :ok = :sys.suspend(pid)
    :ok = Remote.prepare_all()
    assert_receive {:drop, "client/slow1"}, 2000
    :ok = :sys.resume(pid)
    # THAW holds it again: a later handoff carries it
    :ok = Remote.thaw_all()
    assert_receive {:hold, "client/slow1", _, 1}, 2000
    assert :sys.get_state(pid).held
  end

  test "an undrained socket is dropped at prepare, not carried" do
    ctx = setup_listener()
    _s = attached!(attach(ctx, client_id: "stuck1"), false)
    assert_receive {:hold, "client/stuck1", _, 1}, 2000
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(1))

    flood =
      spawn(fn ->
        Stream.iterate(0, &(&1 + 1))
        |> Enum.each(fn i ->
          Fake.Pty.output(pty, "\e[5;1H" <> String.pad_leading("#{i}", 40, "f"))
          Process.sleep(1)
        end)
      end)

    on_exit(fn -> Process.exit(flood, :kill) end)

    wait_until(fn ->
      sock = :sys.get_state(conn("stuck1")).socket
      sock != nil and match?({:ok, [send_pend: n]} when n > 0, :inet.getstat(sock, [:send_pend]))
    end)

    :ok = Remote.prepare_all()
    assert_receive {:drop, "client/stuck1"}, 2000
    refute_received {:update, "client/stuck1", _}
    assert :sys.get_state(conn("stuck1")).socket == nil
  end

  test "thaw restarts the client socket without calling back into the Link" do
    :ok = Link.put_adopted_for_test([])
    dir = Path.join(System.tmp_dir!(), "hlt#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "c.sock")
    opts = [path: path, token_path: Path.join(dir, "c.token")]
    {:ok, _} = Supervisor.start_child(DynideServer.Supervisor, {Socket, opts})

    on_exit(fn ->
      _ = Supervisor.terminate_child(DynideServer.Supervisor, Socket)
      _ = Supervisor.delete_child(DynideServer.Supervisor, Socket)
      File.rm_rf!(dir)
    end)

    # as PREPARE leaves it
    :ok = Supervisor.terminate_child(DynideServer.Supervisor, Socket)
    send(Link, {:dynide_link, nil, NLink.kind(:thaw), "", []})
    # a Link blocked in restart_child (Socket.init calling it back) never answers
    assert %Link{frozen: false} = :sys.get_state(Link, 5000)
    assert Socket.path() == path
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
    assert %{buffer: ^head, acked: -1, prepared: true} = blob(b)

    # neither read nor written while frozen
    :ok = :gen_tcp.send(s, tail)
    send(conn("frz"), {:notice, %{level: :info, text: "held"}})
    assert {:error, :timeout} = recv_frame(s, 300)
    assert typed(1) == ""

    :ok = Remote.thaw_all()
    assert_receive {:update, "client/frz", b}, 2000
    assert %{prepared: false} = blob(b)
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

    b = carried_blob("abc", info, acked: 3, buffer: carried <> head)

    :ok = Link.put_adopted_for_test([{"client/abc", b, [fd]}])
    _ctx = setup_listener()
    :ok = Remote.Supervisor.adopt_all()

    assert {:attached, %{resumed: :handoff}} = recv_frame(c)
    assert {:scene, _} = recv_until(c, &match?({:scene, _}, &1))
    assert_receive {:update, "client/abc", b2}, 2000
    assert %{buffer: "", acked: 3, prepared: false} = blob(b2)

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

  test "a pane conn is never held" do
    ctx = setup_listener()
    attached!(attach(ctx, client_id: "sess1"), false)
    assert_receive {:hold, "client/sess1", _, 1}, 2000
    attached!(attach(ctx, client_id: "pane1", target: {:pane, 1, :control}), false)
    # its hold would come before its first scene
    refute_received {:hold, "client/pane1", _, _}
    :ok = Remote.prepare_all()
    refute_received {:update, "client/pane1", _}
  end

  test "an adopted pane-target entry is unclaimed and closed" do
    {c, fd} = socket_pair()
    info = attach_info(client_id: "padopt", target: {:pane, 1, :observe})
    :ok = Link.put_adopted_for_test([{"client/padopt", carried_blob("padopt", info, []), [fd]}])
    _ctx = setup_listener()
    :ok = Remote.Supervisor.adopt_all()
    assert :closed = recv_closed(c)
    assert :sys.get_state(Link).rejected == ["client/padopt"]
    assert Registry.lookup(Remote.Registry, "padopt") == []
  end

  test "bad blob is unclaimed and the fd closed" do
    {c, fd} = socket_pair()
    :ok = Link.put_adopted_for_test([{"client/bad", "not a term", [fd]}])
    _ctx = setup_listener()
    :ok = Remote.Supervisor.adopt_all()
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
