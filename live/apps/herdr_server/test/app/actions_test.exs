defmodule HerdrServer.App.ActionsTest do
  use ExUnit.Case, async: true
  alias HerdrScene.Event
  alias HerdrServer.App.{Actions, Keybinds}
  alias HerdrServer.Layout

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key, mods \\ []), do: Actions.apply(app, Event.key(key, mods))

  # applies the prefix binding of `key` the way the Store runs it (keys resolve in Client.Keys)
  defp pfx(app, key, mods \\ []) do
    {m, f, a} = Keybinds.lookup(app.ui.keybinds, :prefix, Keybinds.normalize(key, mods))
    Kernel.apply(m, f, [app | a])
  end

  defp ids(app), do: Layout.pane_ids(tab_layout(app))

  defp tab_layout(app) do
    ws = hd(app.session.workspaces)
    Enum.find(ws.tabs, &(&1.id == ws.active_tab)).layout
  end

  test "init" do
    assert {app, [{:spawn, 1, %{cols: 100, rows: 24}}]} = Actions.init(%{cols: 100, rows: 25})
    assert app.session.area == %{x: 0, y: 0, w: 100, h: 24}
    assert app.focus.pane == 1
  end

  test "split, focus, close" do
    {app, eff} = pfx(fresh(), "v")
    assert [{:spawn, 2, _}] = eff
    assert app.focus.pane == 2 and length(ids(app)) == 2
    {app, _} = pfx(app, "h")
    assert app.focus.pane == 1
    {app, _} = pfx(app, "l")
    assert app.focus.pane == 2
    {app, eff} = pfx(app, "x")
    assert eff == [{:close, 2}] and app.focus.pane == 1
  end

  test "keys, presses and releases, go to the focused pane" do
    app = fresh()
    ev = Event.key("a")
    assert {^app, [{:key, 1, ^ev}]} = Actions.apply(app, ev)
    rel = Event.key("b", [:ctrl], event: :release)
    assert {^app, [{:key, 1, ^rel}]} = Actions.apply(app, rel)
  end

  test "resize_dir moves the split" do
    {app, _} = pfx(fresh(), "v")
    ratio = fn a -> hd(Layout.splits(tab_layout(a), a.session.area)).ratio end
    r0 = ratio.(app)
    {app, []} = Actions.resize_dir(app, :left, 0.05)
    r1 = ratio.(app)
    {app, []} = Actions.resize_dir(app, :left, 0.05)
    assert ratio.(app) < r1 and r1 < r0
  end

  test "tabs" do
    {app, _} = pfx(fresh(), "v")
    {app, eff} = pfx(app, "c")
    assert [{:spawn, 3, %{cols: 100, rows: 24}}] = eff
    assert app.focus.pane == 3 and hd(app.session.workspaces).active_tab == 2
    {app, _} = pfx(app, "p")
    assert hd(app.session.workspaces).active_tab == 1 and app.focus.pane == 2
    {app, _} = pfx(app, "2")
    assert hd(app.session.workspaces).active_tab == 2
    {app, _} = pfx(app, "1")
    assert hd(app.session.workspaces).active_tab == 1
    {app, _} = pfx(app, "n")
    {app, eff} = pfx(app, "X", [:shift])
    assert eff == [{:close, 3}] and app.focus.pane == 2
  end

  test "closing last pane respawns; unknown id is a no-op" do
    {app, eff} = pfx(fresh(), "x")
    assert [{:close, 1}, {:spawn, 2, %{cols: 100, rows: 24}}] = eff
    assert app.focus.pane == 2 and app.session.panes |> Map.keys() == [2]
    assert {^app, []} = Actions.apply(app, {:pane_exited, 99})
    assert {_, [{:close, 2}, {:spawn, 3, _}]} = Actions.apply(app, {:pane_exited, 2})
  end

  test "mouse" do
    {app, _} = pfx(fresh(), "v")
    {:mouse, m} = {:mouse, %{kind: :press, button: :left, x: 10, y: 5, mods: [], px: nil}}
    {app, [{:mouse, 1, {:mouse, rel}}]} = Actions.apply(app, {:mouse, m})
    assert app.focus.pane == 1 and rel.x == 9 and rel.y == 4
    # drag in non-focused pane is dropped; scroll in focused is forwarded
    assert {_, []} = Actions.apply(app, {:mouse, %{m | kind: :drag, x: 90}})
    assert {_, [{:mouse, 1, _}]} = Actions.apply(app, {:mouse, %{m | kind: :scroll}})
    assert {_, []} = Actions.apply(app, {:mouse, %{m | y: 24}})
  end

  test "resize event, paste, focus, title" do
    app = fresh()
    {a, []} = Actions.apply(app, {:resize, %{cols: 200, rows: 50, cell_px: nil}})
    assert a.session.area == %{x: 0, y: 0, w: 200, h: 49}
    assert {_, [{:paste, 1, "x"}]} = Actions.apply(a, {:paste, "x"})
    assert {_, [{:focus_report, 1, true}]} = Actions.apply(a, {:focus, true})
    {a, []} = Actions.apply(a, {:pane_title, 1, "t"})
    assert a.session.panes[1].title == "t"
  end

  test "titles are made valid UTF-8 and capped at 256 bytes on a codepoint" do
    app = fresh()
    {a, []} = Actions.apply(app, {:pane_title, 1, <<"ok", 0xFF, "!">>})
    assert a.session.panes[1].title == "ok\uFFFD!"
    {a, []} = Actions.apply(app, {:pane_title, 1, String.duplicate("é", 200)})
    assert a.session.panes[1].title == String.duplicate("é", 128)
    {a, []} = Actions.apply(app, {:pane_title, 1, "a" <> String.duplicate("é", 200)})
    assert a.session.panes[1].title == "a" <> String.duplicate("é", 127)
  end

  defp wide(app), do: elem(Actions.apply(app, {:resize, %{cols: 200, rows: 51, cell_px: nil}}), 0)

  defp content_rects(app) do
    area = app.session.area
    Layout.borders(Layout.panes(tab_layout(app), area), area)
  end

  defp focus_pane(app, id) do
    app = put_in(app.focus.pane, id)

    update_in(app.session.workspaces, fn ws ->
      Enum.map(ws, fn w ->
        %{w | tabs: Enum.map(w.tabs, &%{&1 | layout: Layout.focus(&1.layout, id)})}
      end)
    end)
  end

  test "splitting the newest pane repeatedly is eventually refused, never zero-size" do
    {app, refused} =
      Enum.reduce_while(1..60, {wide(fresh()), nil}, fn i, {a, _} ->
        {a2, eff} = pfx(a, if(rem(i, 2) == 0, do: "-", else: "v"))

        case eff do
          [{:notice, %{level: :warning, text: "pane too small to split"}}] ->
            {:halt, {a2, a}}

          _ ->
            assert Enum.all?(content_rects(a2), &(&1.rect.w > 0 and &1.rect.h > 0))
            {:cont, {a2, nil}}
        end
      end)

    assert refused, "never refused"
    assert length(ids(app)) == length(ids(refused))
  end

  test "balanced splits reach 15 panes at 200x50 with positive content rects" do
    app =
      Enum.reduce(1..14, wide(fresh()), fn _, a ->
        %{id: big, rect: r} = Enum.max_by(content_rects(a), &(&1.rect.w * &1.rect.h))
        {a, [{:spawn, _, _}]} = pfx(focus_pane(a, big), if(r.w >= 2 * r.h, do: "v", else: "-"))
        a
      end)

    rects = content_rects(app)
    assert length(rects) == 15
    assert Enum.all?(rects, &(&1.rect.w > 0 and &1.rect.h > 0))
  end
end
