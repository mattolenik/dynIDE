defmodule HerdrIntegration.RemoteClientTest do
  @moduledoc """
  The real socket transport end to end in one VM: `Client.Socket` + `Client.Remote` on a
  tmp unix socket, a remote client (`Remote.Conn`, inline transport) and a local ref
  client attached to the same session.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrIntegration.Driver
  alias HerdrServer.App.Store
  alias HerdrServer.Client.{Remote, Socket}
  alias HerdrTerm.Remote.Conn

  @wait 3_000

  setup do
    Driver.reset()
    on_exit(&Driver.reset/0)
    dir = Path.join(System.tmp_dir!(), "hlr#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    sock = Path.join(dir, "c.sock")
    token = Path.join(dir, "c.token")
    start_supervised!({Socket, path: sock, token_path: token})
    %{transport: {:unix, sock, token}}
  end

  defp start_remote(ctx, size) do
    client_id = "it#{System.unique_integer([:positive])}"
    name = :"conn_#{client_id}"

    conn =
      start_supervised!(
        {Conn, name: name, transport: ctx.transport, session: nil, client_id: client_id},
        id: name
      )

    client = Driver.start_client(size, endpoint: name, transport: :inline)
    {client, conn, client_id}
  end

  defp has?(client, text), do: Driver.wait_screen(client, &(Enum.join(&1) =~ text), @wait)

  defp pane_ids(client), do: Enum.map(Driver.scene(client).panes, & &1.id)

  test "remote and local clients of different sizes", ctx do
    local = Driver.start_client({120, 40})
    {remote, _conn, _id} = start_remote(ctx, {80, 24})

    Driver.type(local, "abc")
    assert has?(local, "abc")
    assert has?(remote, "abc")

    Driver.type(remote, "xyz")
    assert has?(local, "abcxyz")
    assert has?(remote, "abcxyz")

    assert Driver.scene(local).size == %{cols: 120, rows: 40}
    assert Driver.scene(remote).size == %{cols: 80, rows: 24}
    assert pane_ids(local) == pane_ids(remote)
  end

  test "disconnect and reconnect preserves the session", ctx do
    {remote, _conn, id} = start_remote(ctx, {80, 24})
    Driver.type(remote, "before")
    assert has?(remote, "before")
    panes = pane_ids(remote)

    [{server_conn, _}] = Registry.lookup(Remote.Registry, id)
    old = :sys.get_state(server_conn).socket
    assert is_port(old)
    # the server side of the socket goes away; the client reconnects (backoff 100 ms)
    :ok = :gen_tcp.shutdown(old, :read_write)

    assert eventually(fn ->
             s = :sys.get_state(server_conn).socket
             is_port(s) and s != old
           end)

    Driver.type(remote, "after")
    assert has?(remote, "beforeafter")
    assert pane_ids(remote) == panes
  end

  test "store restart keeps the remote client", ctx do
    {remote, _conn, _id} = start_remote(ctx, {80, 24})
    Driver.type(remote, "one")
    assert has?(remote, "one")

    # terminate + restart, not a kill: a kill spends HerdrServer.Supervisor's restart budget
    # (3 in 5 s), which the umbrella VM shares with herdr_server's own kill tests just before
    old = Process.whereis(Store)
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)
    assert Process.whereis(Store) not in [nil, old]

    Driver.type(remote, "two")
    assert has?(remote, "two")
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end
end
