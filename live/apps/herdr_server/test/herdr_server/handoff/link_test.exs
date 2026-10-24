defmodule HerdrServer.Handoff.LinkTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Handoff.{Link, Notice, State}
  alias HerdrServer.Native.Keeper
  alias HerdrServer.Native.Link, as: NLink

  test "init is :ignore without HERDR_BROKER_SOCK" do
    assert System.get_env("HERDR_BROKER_SOCK") == nil
    assert Link.init([]) == :ignore
    refute Link.enabled?()
    assert Link.hold("k", "b", []) == :ok
    assert Link.restored() == :ok
    assert Link.take_adopted("pane/") == []
  end

  test "hold is sent before open replies" do
    path = "/tmp/hh-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    {:ok, link} = NLink.connect(path, self())
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    :persistent_term.put({Link, :link}, link)

    on_exit(fn ->
      :persistent_term.erase({Link, :link})
      NLink.close(link)
      :gen_tcp.close(l)
      File.rm(path)
    end)

    spec = %{
      cmd: "/bin/sh",
      args: [],
      env: [],
      cwd: nil,
      cols: 80,
      rows: 24,
      max_scrollback: 1000,
      subscriber: nil
    }

    {:ok, id} = Keeper.open(spec)
    # already on the socket when open returns: no waiting
    assert {:ok, <<len::32, 0x02, 1>>} = :gen_tcp.recv(peer, 6, 0)
    {:ok, body} = :gen_tcp.recv(peer, len - 2, 1000)
    key = "pane/#{id}"
    assert {^key, blob} = NLink.parse_key(body)
    {:ok, %{os_pid: os_pid}} = Keeper.lookup(id)

    assert {:ok, %{v: 1, id: ^id, os_pid: ^os_pid, vt: nil, cols: 80, rows: 24}} =
             State.decode(blob)

    :ok = Keeper.close(id)
    assert {:ok, <<_::32, 0x04, 0>>} = :gen_tcp.recv(peer, 6, 1000)
    {:ok, drop} = :gen_tcp.recv(peer, byte_size(key) + 2, 1000)
    assert NLink.parse_key(drop) == {key, ""}
  end

  defp frame(peer) do
    {:ok, <<len::32, kind, _nfds>>} = :gen_tcp.recv(peer, 6, 5000)
    {:ok, body} = if len > 2, do: :gen_tcp.recv(peer, len - 2, 5000), else: {:ok, ""}
    {kind, body}
  end

  test "hello, fresh, request and prepare/thaw against a fake broker" do
    path = "/tmp/hb-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    System.put_env("HERDR_BROKER_SOCK", path)
    System.put_env("HERDR_LIVE_GEN", "7")

    on_exit(fn ->
      System.delete_env("HERDR_BROKER_SOCK")
      System.delete_env("HERDR_LIVE_GEN")
      :persistent_term.erase({Link, :link})
      :gen_tcp.close(l)
      File.rm(path)
    end)

    starter = Task.async(fn -> Link.start_link([]) end)
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    os_pid = String.to_integer(System.pid())
    assert frame(peer) == {0x01, <<7::64, os_pid::32>>}
    :ok = :gen_tcp.send(peer, <<2::32, 0x41, 0>>)
    {:ok, pid} = Task.await(starter)
    assert Link.enabled?()
    assert Link.adopt_reason() == nil
    assert Link.restored() == :ok

    req = :erlang.term_to_binary(:ping)
    :ok = :gen_tcp.send(peer, [<<byte_size(req) + 10::32, 0x47, 0, 42::64>>, req])
    assert {0x07, <<42::64, reply::binary>>} = frame(peer)
    assert :erlang.binary_to_term(reply) == :pong

    :ok = Notice.subscribe()
    :ok = :gen_tcp.send(peer, <<2::32, 0x44, 0>>)
    assert_receive {:handoff, %{phase: :begin, gen: 7}}, 5000
    # final UPDATEs for every pane, then PREPARED
    assert {0x06, ""} =
             Enum.find(Stream.repeatedly(fn -> frame(peer) end), &(elem(&1, 0) != 0x03))

    :ok = :gen_tcp.send(peer, <<2::32, 0x46, 0>>)
    assert_receive {:handoff, %{phase: :aborted, gen: 7}}, 5000

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
  end
end
