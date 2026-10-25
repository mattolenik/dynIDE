defmodule HerdrServer.Client.RemotePaneTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import HerdrServer.Test.WireClient

  alias HerdrScene.Event
  alias HerdrServer.Client.Remote
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows

  setup do
    ctx = setup_listener()
    # a session client initialises the app (pane 1)
    s = attach(ctx)
    assert {:attached, _} = recv_frame(s)
    scene!(s)
    Map.put(ctx, :session, s)
  end

  defp pty(id) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    pty
  end

  defp typed(id), do: Fake.Pty.writes(pty(id)) |> Enum.join()

  defp scene!(s), do: elem(recv_until(s, &match?({:scene, _}, &1)), 1)
  defp ack!(s, n), do: assert({:ack, ^n} = recv_until(s, &match?({:ack, ^n}, &1)))

  defp pane!(ctx, id, mode) do
    p = attach(ctx, target: {:pane, id, mode})
    assert {:attached, %{resumed: false}} = recv_frame(p)
    p
  end

  # a session-mode prefix command (its scene follows)
  defp prefix!(s, seq, key) do
    :ok = send_frame(s, {:input, seq, Event.key("b", [:ctrl])})
    :ok = send_frame(s, {:input, seq + 1, Event.key(key)})
  end

  defp panes(s, n), do: scene_until(s, &(length(&1.panes) == n))

  defp scene_until(s, pred),
    do: elem(recv_until(s, &(match?({:scene, sc} when is_map(sc), &1) and pred.(elem(&1, 1)))), 1)

  test "observe gets the pane rows and ignores keys", ctx do
    Fake.Pty.output(pty(1), "before")
    p = pane!(ctx, 1, :observe)
    sc = scene!(p)
    assert [%{id: 1, rect: %{x: 0, y: 0, w: 80}}] = sc.panes
    assert sc.focus.pane == 1
    assert shows?({:scene, sc}, "before")

    :ok = send_frame(p, {:input, 1, Event.key("x")})
    ack!(p, 1)
    Fake.Pty.output(pty(1), "after")
    assert recv_until(p, &shows?(&1, "after"))
    assert typed(1) == ""
  end

  test "control writes keys to the pane even when another pane is focused", ctx do
    s = ctx.session
    prefix!(s, 1, "v")
    assert panes(s, 2).focus.pane == 2

    p = pane!(ctx, 1, :control)
    scene!(p)
    :ok = send_frame(p, {:input, 1, Event.key("z")})
    ack!(p, 1)
    assert recv_until(p, &shows?(&1, "z"))
    assert typed(1) == "z"
    assert typed(2) == ""
  end

  test "observing a pane on another tab works", ctx do
    s = ctx.session
    Fake.Pty.output(pty(1), "tab one")
    assert recv_until(s, &shows?(&1, "tab one"))
    prefix!(s, 1, "c")
    assert [%{id: 2}] = scene_until(s, &match?([%{id: 2}], &1.panes)).panes

    p = pane!(ctx, 1, :observe)
    assert shows?({:scene, scene!(p)}, "tab one")

    # hidden pane 1: nothing of it reaches the session client
    Fake.Pty.output(pty(1), "hidden out")
    :ok = send_frame(s, {:input, 3, Event.key("y")})

    seen =
      recv_until(s, fn f ->
        refute match?({:rows, 1, _, _}, f)
        refute match?({:scene, %{panes: [_, _ | _]}}, f)
        shows?(f, "y")
      end)

    assert seen
  end

  test "closing the pane detaches observers", ctx do
    s = ctx.session
    prefix!(s, 1, "v")
    panes(s, 2)
    p = pane!(ctx, 2, :observe)
    scene!(p)
    prefix!(s, 3, "x")
    assert {:detached, :pane_closed} = recv_until(p, &match?({:detached, _}, &1))
    assert recv_closed(p) == :closed
  end

  test "unknown pane refused", ctx do
    p = attach(ctx, target: {:pane, 99, :observe})
    assert recv_frame(p) == {:refused, "no pane p99"}
    assert {:error, :closed} = recv_frame(p)
  end

  test "a lost socket stops the conn at once", ctx do
    p = pane!(ctx, 1, :observe)
    scene!(p)
    [conn] = for %{target: {:pane, 1, :observe}} = c <- Remote.list(), do: c
    [{pid, _}] = Registry.lookup(Remote.Registry, conn.id)
    ref = Process.monitor(pid)
    :gen_tcp.close(p)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 2000
  end
end
