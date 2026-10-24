defmodule HerdrServer.App.ActionsTest do
  use ExUnit.Case, async: true
  alias HerdrScene.Event
  alias HerdrServer.App.Actions
  alias HerdrServer.Layout

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key, mods \\ []), do: Actions.apply(app, Event.key(key, mods))

  defp run(app, keys) do
    Enum.reduce(keys, {app, []}, fn k, {a, _} ->
      {key, mods} = if is_tuple(k), do: k, else: {k, []}
      press(a, key, mods)
    end)
  end

  defp pfx(app, key, mods \\ []), do: run(app, [{"b", [:ctrl]}, {key, mods}])
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
    assert app.focus.pane == 2 and length(ids(app)) == 2 and app.focus.mode == :terminal
    {app, _} = pfx(app, "h")
    assert app.focus.pane == 1
    {app, _} = pfx(app, "l")
    assert app.focus.pane == 2
    {app, eff} = pfx(app, "x")
    assert eff == [{:close, 2}] and app.focus.pane == 1
  end

  test "typing, double prefix, unbound" do
    app = fresh()
    ev = Event.key("a")
    assert {_, [{:key, 1, ^ev}]} = Actions.apply(app, ev)
    pev = Event.key("b", [:ctrl])
    {a, []} = Actions.apply(app, pev)
    assert a.focus.mode == :prefix
    assert {a2, [{:key, 1, ^pev}]} = Actions.apply(a, pev)
    assert a2.focus.mode == :terminal
    {a, []} = Actions.apply(a, Event.key("z"))
    assert a.focus.mode == :terminal
    {a, []} = Actions.apply(app, pev)
    assert {^a, []} = Actions.apply(a, Event.key("c", [], event: :release))
  end

  test "resize mode" do
    {app, _} = pfx(fresh(), "v")
    {app, _} = pfx(app, "r")
    assert app.focus.mode == :resize
    ratio = fn a -> elem(tab_layout(a).root, 2) end
    r0 = ratio.(app)
    {app, []} = press(app, "h")
    r1 = ratio.(app)
    {app, []} = press(app, "h")
    assert ratio.(app) < r1 and r1 < r0 and app.focus.mode == :resize
    {app, []} = press(app, "q")
    assert app.focus.mode == :resize
    {app, []} = press(app, :escape)
    assert app.focus.mode == :terminal
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

  test "15 alternating splits keep positive content rects" do
    {app, _} = Actions.apply(fresh(), {:resize, %{cols: 200, rows: 51, cell_px: nil}})

    app =
      Enum.reduce(1..14, app, fn i, a ->
        {a, _} = pfx(a, if(rem(i, 2) == 0, do: "-", else: "v"))
        {a, _} = pfx(a, "tab" |> String.to_atom())
        a
      end)

    area = app.session.area
    rects = Layout.borders(Layout.panes(tab_layout(app), area), area)
    assert length(rects) == 15
    assert Enum.all?(rects, &(&1.rect.w > 0 and &1.rect.h > 0))
  end
end
