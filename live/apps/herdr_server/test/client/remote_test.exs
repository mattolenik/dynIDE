defmodule HerdrServer.Client.RemoteTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import HerdrServer.Test.WireClient

  alias HerdrScene.{Event, Scene}
  alias HerdrServer.Client.Remote
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows

  setup do
    setup_listener()
  end

  defp pty(id) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    pty
  end

  defp attached!(s, resumed \\ false) do
    assert {:attached, %{resumed: ^resumed, session: "default"}} = recv_frame(s)
    s
  end

  defp scene!(s), do: elem(recv_until(s, &match?({:scene, _}, &1)), 1)
  defp ack!(s, n), do: assert({:ack, ^n} = recv_until(s, &match?({:ack, ^n}, &1)))

  defp conn(id) do
    [{pid, _}] = Registry.lookup(Remote.Registry, id)
    pid
  end

  defp entry(id), do: Enum.find(Remote.list(), &(&1.id == id))

  defp wait_until(fun, n \\ 200) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, n - 1)
    end
  end

  defp mode_text(scene), do: Scene.Node.find(scene.chrome, [:status, :mode]).text

  defp typed(id), do: Fake.Pty.writes(pty(id)) |> Enum.join()

  defp put_cfg(key, value) do
    old = Application.get_env(:herdr_server, :client_socket, [])
    Application.put_env(:herdr_server, :client_socket, Keyword.put(old, key, value))
    on_exit(fn -> Application.put_env(:herdr_server, :client_socket, old) end)
  end

  # pane 1 rewrites a row every millisecond until the test ends
  defp flood! do
    pty = pty(1)

    flood =
      spawn(fn ->
        Stream.iterate(0, &(&1 + 1))
        |> Enum.each(fn i ->
          Fake.Pty.output(pty, "\e[5;1H" <> String.pad_leading("#{i}", 40, "f"))
          Process.sleep(1)
        end)
      end)

    on_exit(fn -> Process.exit(flood, :kill) end)
    flood
  end

  # a never-reading client's socket buffers are full
  defp stuck!(id) do
    wait_until(fn ->
      s = :sys.get_state(conn(id)).socket
      s != nil and match?({:ok, [send_pend: n]} when n > 0, :inet.getstat(s, [:send_pend]))
    end)
  end

  test "typing echoes as rows", ctx do
    s = attached!(attach(ctx))
    scene!(s)
    :ok = send_frame(s, {:input, 1, Event.key("x")})
    ack!(s, 1)
    assert recv_until(s, &shows?(&1, "x"))
    assert typed(1) == "x"
  end

  test "list shows the conn", ctx do
    s = attached!(attach(ctx, client_id: "listme12345"))
    scene!(s)

    assert %{kind: :term, target: :session, size: %{cols: 80, rows: 24}, connected: true} =
             entry("listme12345")
  end

  test "2 MiB paste is delivered", ctx do
    s = attached!(attach(ctx))
    scene!(s)
    big = :binary.copy("p", 2 * 1_048_576)
    :ok = send_frame(s, {:input, 1, {:paste, big}})
    assert {:ack, 1} = recv_until(s, &match?({:ack, _}, &1), 20_000)
    assert byte_size(typed(1)) == byte_size(big)
  end

  test "drop and resume keeps the session", ctx do
    s = attached!(attach(ctx, client_id: "resume-me"))
    scene!(s)
    conn = conn("resume-me")
    session = :sys.get_state(conn).session
    :ok = send_frame(s, {:input, 1, Event.key("b", [:ctrl])})
    assert {:input_mode, :prefix} = recv_until(s, &match?({:input_mode, _}, &1))
    ack!(s, 1)
    :gen_tcp.close(s)
    wait_until(fn -> entry("resume-me").connected == false end)

    s = attached!(attach(ctx, client_id: "resume-me"), true)
    sc = scene!(s)
    assert mode_text(sc) == "PREFIX"
    assert [%{rows: {:inline, rows}, rect: rect}] = sc.panes
    assert length(rows) == rect.h
    assert {:input_mode, :prefix} = recv_until(s, &match?({:input_mode, _}, &1))
    assert conn("resume-me") == conn
    assert :sys.get_state(conn).session == session
    assert entry("resume-me").connected
  end

  test "resume with another size resizes the session", ctx do
    s = attached!(attach(ctx, client_id: "resize-me"))
    scene!(s)
    :gen_tcp.close(s)
    wait_until(fn -> entry("resize-me").connected == false end)

    s = attached!(attach(ctx, client_id: "resize-me", size: %{cols: 100, rows: 30}), true)
    sc = recv_until(s, &match?({:scene, %{size: %{cols: 100}}}, &1))
    assert {:scene, %{size: %{rows: 30}}} = sc
    # the internal resize's ack is swallowed
    :ok = send_frame(s, {:input, 1, Event.key("a")})
    assert {:ack, 1} = recv_until(s, &match?({:ack, _}, &1))
  end

  test "grace expiry ends the session", ctx do
    put_cfg(:grace_ms, 100)

    s = attached!(attach(ctx, client_id: "grace-me"))
    scene!(s)
    conn = conn("grace-me")
    cref = Process.monitor(conn)
    sref = Process.monitor(:sys.get_state(conn).session)
    :gen_tcp.close(s)
    assert_receive {:DOWN, ^cref, :process, _, :normal}, 3000
    assert_receive {:DOWN, ^sref, :process, _, :normal}, 3000
    # the Registry unregisters on its own :EXIT, a moment later
    wait_until(fn -> Registry.lookup(Remote.Registry, "grace-me") == [] end)
  end

  test "same input resent after resume is not applied twice", ctx do
    s = attached!(attach(ctx, client_id: "once"))
    scene!(s)
    :ok = send_frame(s, {:input, 5, Event.key("a")})
    :gen_tcp.close(s)

    s = attached!(attach(ctx, client_id: "once"), true)
    :ok = send_frame(s, {:input, 5, Event.key("a")})
    ack!(s, 5)
    :ok = send_frame(s, {:input, 6, Event.key("b")})
    ack!(s, 6)
    assert typed(1) == "ab"
  end

  test "an old wire seq is re-acked, not applied", ctx do
    s = attached!(attach(ctx))
    scene!(s)
    :ok = send_frame(s, {:input, 1, Event.key("a")})
    ack!(s, 1)
    :ok = send_frame(s, {:input, 1, Event.key("a")})
    ack!(s, 1)
    assert typed(1) == "a"
  end

  test "same client_id twice replaces the first", ctx do
    a = attached!(attach(ctx, client_id: "twin"))
    scene!(a)
    conn = conn("twin")
    b = attached!(attach(ctx, client_id: "twin"), true)
    scene!(b)
    assert {:detached, :replaced} = recv_until(a, &match?({:detached, _}, &1))
    assert recv_frame(a) == {:error, :closed}
    assert conn("twin") == conn
    :ok = send_frame(b, {:input, 1, Event.key("a")})
    ack!(b, 1)
  end

  test "detach ends the session and closes the socket", ctx do
    s = attached!(attach(ctx, client_id: "bye"))
    scene!(s)
    ref = Process.monitor(conn("bye"))
    :ok = send_frame(s, {:detach})
    assert {:detached, :requested} = recv_until(s, &match?({:detached, _}, &1))
    assert recv_frame(s) == {:error, :closed}
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 3000
  end

  test "blocked reader does not stall another client", ctx do
    a = attached!(attach(ctx, client_id: "blocked"))
    b = attached!(attach(ctx))
    scene!(b)
    flood = flood!()
    stuck!("blocked")

    :ok = send_frame(b, {:input, 1, Event.key("z")})
    assert recv_until(b, &shows?(&1, "z"), 500)

    a_conn = conn("blocked")
    {:message_queue_len, n} = Process.info(a_conn, :message_queue_len)
    assert n < 1000
    Process.exit(flood, :kill)
    :gen_tcp.close(a)
  end

  test "list reports the size after a client resize", ctx do
    s = attached!(attach(ctx, client_id: "list-size"))
    :ok = send_frame(s, {:input, 1, {:resize, %{cols: 120, rows: 40, cell_px: nil}}})
    wait_until(fn -> entry("list-size").size == %{cols: 120, rows: 40} end)
    :gen_tcp.close(s)
  end

  test "a resize, a drop and a resume at the attach size renders at that size", ctx do
    s = attached!(attach(ctx, client_id: "own-resize"))
    scene!(s)
    :ok = send_frame(s, {:input, 1, {:resize, %{cols: 120, rows: 40, cell_px: nil}}})
    assert recv_until(s, &match?({:scene, %{size: %{cols: 120}}}, &1))
    ack!(s, 1)
    :gen_tcp.close(s)
    wait_until(fn -> entry("own-resize").connected == false end)

    s = attached!(attach(ctx, client_id: "own-resize"), true)

    assert {:scene, %{size: %{rows: 24}}} =
             recv_until(s, &match?({:scene, %{size: %{cols: 80}}}, &1))
  end

  test "same client_id while the first is a blocked reader resumes promptly", ctx do
    a = attached!(attach(ctx, client_id: "stuck-twin"))
    scene!(a)
    flood!()
    stuck!("stuck-twin")
    t = System.monotonic_time(:millisecond)
    b = attached!(attach(ctx, client_id: "stuck-twin"), true)
    assert System.monotonic_time(:millisecond) - t < 2000
    scene!(b)
    :ok = send_frame(b, {:input, 1, Event.key("a")})
    ack!(b, 1)
    :gen_tcp.close(a)
  end

  test "a reader stuck past stuck_ms is dropped; grace applies", ctx do
    put_cfg(:stuck_ms, 200)
    a = attached!(attach(ctx, client_id: "stuck"))
    scene!(a)
    flood!()
    wait_until(fn -> entry("stuck").connected == false end, 500)
    assert Process.alive?(conn("stuck"))
    :gen_tcp.close(a)
  end

  test "input after attach in the same packet as the handshake, over the handshake cap", ctx do
    s = connect(ctx.path)
    big = :binary.copy("q", 100_000)

    :ok =
      :gen_tcp.send(s, [
        HerdrScene.Wire.encode({:auth, ctx.token}),
        HerdrScene.Wire.encode({:attach, attach_info()}),
        HerdrScene.Wire.encode({:input, 1, {:paste, big}})
      ])

    attached!(s)
    assert {:ack, 1} = recv_until(s, &match?({:ack, _}, &1), 10_000)
    assert byte_size(typed(1)) == byte_size(big)
  end
end
