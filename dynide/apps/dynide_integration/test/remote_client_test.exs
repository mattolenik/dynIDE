defmodule DynideIntegration.RemoteClientTest do
  @moduledoc """
  The real socket transport end to end in one VM: `Client.Socket` + `Client.Remote` on a
  tmp unix socket, a remote client (`Remote.Conn`, inline transport) and a local ref
  client attached to the same session.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideIntegration.Driver
  alias DynideServer.App.Store
  alias DynideServer.Client.{Remote, Socket}
  alias DynideServer.Kernel.Fake.{Keeper, Vt}
  alias DynideServer.Pane.Rows
  alias DynideTerm.Client
  alias DynideTerm.Remote.Conn

  @wait 3_000

  setup do
    Driver.reset()
    on_exit(&Driver.reset/0)
    dir = Path.join(System.tmp_dir!(), "hlr#{System.pid()}-#{System.unique_integer([:positive])}")
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

    # terminate + restart, not a kill: a kill spends DynideServer.Supervisor's restart budget
    # (3 in 5 s), which the umbrella VM shares with dynide_server's own kill tests just before
    old = Process.whereis(Store)
    :ok = Supervisor.terminate_child(DynideServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(DynideServer.Supervisor, Store)
    assert Process.whereis(Store) not in [nil, old]

    Driver.type(remote, "two")
    assert has?(remote, "two")
  end

  @img %{format: :rgba, width: 2, height: 1, bytes: 8, data: <<0::64>>}

  defp placement do
    %{
      image: {7, 42},
      placement: 3,
      x: 0,
      y: 0,
      cols: 4,
      rows: 2,
      x_off: 0,
      y_off: 0,
      src: {0, 0, 0, 0},
      px: {0, 0},
      z: 0,
      size: {2, 1},
      format: :rgba,
      bytes: 8
    }
  end

  defp images(client), do: :sys.get_state(Client.render(client)).gfx.images

  defp show_image(client) do
    [id] = pane_ids(client)
    {:ok, %{vt: vt}} = Keeper.lookup(Rows.kernel_id(id))
    :ok = Vt.set_graphics(vt, [placement()], %{7 => @img})
    Driver.output(id, "x")
    id
  end

  test "a socket client gets the kitty image before the scene placing it", ctx do
    {remote, _conn, _id} = start_remote(ctx, {80, 24})
    id = show_image(remote)
    assert eventually(fn -> images(remote) == %{{id, 7, 42} => @img} end)
  end

  test "an image over the remote cap arrives withheld", ctx do
    Application.put_env(:dynide_server, :remote_image_max_bytes, 4)
    on_exit(fn -> Application.delete_env(:dynide_server, :remote_image_max_bytes) end)
    {remote, _conn, _id} = start_remote(ctx, {80, 24})
    id = show_image(remote)
    assert eventually(fn -> images(remote) == %{{id, 7, 42} => %{@img | data: nil}} end)
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
