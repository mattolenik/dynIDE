defmodule HerdrServer.App.ActionsTest do
  use ExUnit.Case, async: true
  alias HerdrScene.Event
  alias HerdrServer.App.{Actions, Commands, Keybinds}
  alias HerdrServer.Layout

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)

  defp hiding do
    app = fresh()
    {app, _} = Actions.apply(app, {:resize, %{cols: 100, rows: 25}})
    app = put_in(app, [Access.key(:ui), Access.key(:tab_bar), :hide_single], true)
    Actions.reframe(app)
  end

  test "new_tab and close_tab reframe when the tab bar hides for a single tab" do
    app = hiding()
    assert app.session.area.y == 0
    {app, [{:spawn, _, _}]} = Actions.new_tab(app)
    assert app.session.area.y == 1
    {app, _} = Actions.close_tab(app)
    assert app.session.area.y == 0
  end

  test "switching to a workspace with another tab count reframes" do
    {app, _} = Actions.new_tab(hiding())
    {app, _} = Actions.new_workspace(app)
    assert app.session.area.y == 0
    {app, _} = Actions.switch_workspace(app, 1)
    assert app.session.area.y == 1
  end

  test "API tab create and close reframe" do
    app = hiding()
    {app, _} = Commands.create_tab(app, 1, nil, true)
    assert app.session.area.y == 1
    {app, _} = Commands.close_tab(app, 1, 2)
    assert app.session.area.y == 0
  end

  defp press(app, key, mods \\ []), do: Actions.apply(app, Event.key(key, mods))

  # applies the prefix binding of `key` the way the Store runs it (keys resolve in Client.Keys)
  defp pfx(app, key, mods \\ []) do
    {m, f, a} = Keybinds.lookup(app.ui.keybinds, :prefix, Keybinds.normalize(key, mods))
    Kernel.apply(m, f, [app | a])
  end

  defp ids(app), do: Layout.pane_ids(tab_layout(app))

  defp tab_layout(app), do: tab(app).layout

  defp tab(app) do
    ws = hd(app.session.workspaces)
    Enum.find(ws.tabs, &(&1.id == ws.active_tab))
  end

  defp zoom(app), do: Map.get(tab(app), :zoom)

  # two side-by-side panes, pane 2 focused and zoomed
  defp zoomed do
    {app, _} = pfx(fresh(), "v")
    {app, []} = pfx(app, "z")
    app
  end

  test "init" do
    assert {app, [{:spawn, 1, %{cols: 74, rows: 23}}]} = Actions.init(%{cols: 100, rows: 25})
    assert app.session.area == %{x: 26, y: 1, w: 74, h: 23}
    assert app.session.size == %{cols: 100, rows: 25}
    assert app.focus.pane == 1
  end

  test "resize keeps the size and the frame's pane area" do
    {app, []} = Actions.apply(fresh(), {:resize, %{cols: 120, rows: 40, cell_px: nil}})
    assert app.session.size == %{cols: 120, rows: 40}
    assert app.session.area == %{x: 26, y: 1, w: 94, h: 38}
    {app, []} = Actions.apply(app, {:resize, %{cols: 30, rows: 1}})
    assert app.session.area == %{x: 0, y: 0, w: 30, h: 1}
  end

  test "prefix b toggles the sidebar collapsed and recomputes the area" do
    {app, []} = pfx(fresh(), "b")
    assert app.ui.sidebar.collapsed
    assert app.session.area == %{x: 4, y: 1, w: 96, h: 23}
    {app, []} = pfx(app, "b")
    refute app.ui.sidebar.collapsed
    assert app.session.area == %{x: 26, y: 1, w: 74, h: 23}
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

  test "prefix z zooms the focused pane to the whole area; toggling twice clears it" do
    app = zoomed()
    assert zoom(app) == 2
    area = app.session.area
    assert [%{id: 2, rect: ^area, border: nil}] = content_rects(app)
    {app, []} = pfx(app, "z")
    refute Map.has_key?(tab(app), :zoom)
    assert length(content_rects(app)) == 2
  end

  test "split while zoomed clears the zoom first and splits the pane's own tile" do
    {app, [{:spawn, 3, size}]} = pfx(zoomed(), "v")
    assert zoom(app) == nil and length(ids(app)) == 3
    # pane 2's tile is half of the 74-column area; a zoomed split would see all of it
    assert size.cols < 20
  end

  test "closing any pane of the zoomed tab clears the zoom" do
    {app, [{:close, 2}]} = Actions.close_pane(zoomed(), 2)
    assert zoom(app) == nil

    {app, _} = pfx(fresh(), "v")
    {app, _} = pfx(app, "v")
    {app, []} = Actions.toggle_zoom(app)
    {app, [{:close, 1}]} = Actions.close_pane(app, 1)
    assert zoom(app) == nil
  end

  test "focus moves, swaps, resizes and divider drags clear the zoom" do
    for f <- [
          &Actions.focus_dir(&1, :left),
          &Actions.cycle(&1, :next),
          &Actions.swap_dir(&1, :left),
          &Actions.resize_dir(&1, :left, 0.05),
          &Actions.apply(&1, {:chrome, [{:divider, []}], {:drag, %{x: 40, y: 5}}})
        ] do
      {app, []} = f.(zoomed())
      assert zoom(app) == nil
    end
  end

  test "focus_pane clears a zoom that hides the pane, and keeps one on it" do
    {app, []} = Actions.focus_pane(zoomed(), 2)
    assert zoom(app) == 2
    {app, []} = Actions.focus_pane(app, 1)
    assert zoom(app) == nil and app.focus.pane == 1
  end

  test "keys, presses and releases, go to the focused pane" do
    app = fresh()
    ev = Event.key("a")
    assert {^app, [{:key, 1, ^ev}]} = Actions.apply(app, ev)
    rel = Event.key("b", [:ctrl], event: :release)
    assert {^app, [{:key, 1, ^rel}]} = Actions.apply(app, rel)
  end

  test "focus_pane focuses a pane by id; an unknown id is a no-op" do
    {app, _} = pfx(fresh(), "v")
    assert app.focus.pane == 2
    assert {app, []} = Actions.focus_pane(app, 1)
    assert app.focus.pane == 1
    assert {^app, []} = Actions.focus_pane(app, 99)
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
    # c asks for the new tab's name first; Enter keeps the suggested "2"
    {app, []} = pfx(app, "c")
    {app, eff} = press(app, :enter)
    assert [{:spawn, 3, %{cols: 74, rows: 23}}] = eff
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
    # the bare action (the x binding confirms first, see Modal.ConfirmTest)
    {app, eff} = Actions.close_pane(fresh())
    assert [{:close, 1}, {:spawn, 2, %{cols: 74, rows: 23}}] = eff
    assert app.focus.pane == 2 and app.session.panes |> Map.keys() == [2]
    assert {^app, []} = Actions.apply(app, {:pane_exited, 99})
    assert {_, [{:close, 2}, {:spawn, 3, _}]} = Actions.apply(app, {:pane_exited, 2})
  end

  test "mouse" do
    {app, _} = pfx(fresh(), "v")
    # pane 1's content starts at (27, 2): right of the sidebar, under the tab bar
    {:mouse, m} = {:mouse, %{kind: :press, button: :left, x: 36, y: 6, mods: [], px: nil}}
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
    assert a.session.area == %{x: 26, y: 1, w: 174, h: 48}
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
    Layout.rects(tab_layout(app), app.session.area, Layout.opts(tab(app), app.ui))
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

  describe "agent meta" do
    # pane 2 lives in a background tab
    defp with_bg_agent do
      {app, _} = Commands.create_tab(fresh(), 1, nil, false)
      {app, []} = Actions.apply(app, {:pane_agent, 2, "claude"})
      {app, _} = Actions.apply(app, {:agent_state, 2, :working})
      app
    end

    test "a background tab's agent that goes idle is done and alerts finished" do
      {app, [{:alert, alert}]} = Actions.apply(with_bg_agent(), {:agent_state, 2, :idle})
      assert app.session.panes[2].agent_state == :done
      assert alert.title == "claude finished"
    end

    test "an active tab's agent that goes idle is idle" do
      {app, []} = Actions.apply(fresh(), {:pane_agent, 1, "claude"})
      {app, _} = Actions.apply(app, {:agent_state, 1, :working})
      {app, _} = Actions.apply(app, {:agent_state, 1, :idle})
      assert app.session.panes[1].agent_state == :idle
    end

    test "a nil agent clears the label and the state" do
      {app, []} = Actions.apply(with_bg_agent(), {:pane_agent, 2, nil})
      assert app.session.panes[2].agent == nil
      assert app.session.panes[2].agent_state == nil
    end

    test "unknown panes are ignored" do
      app = fresh()
      assert Actions.apply(app, {:pane_agent, 99, "claude"}) == {app, []}
    end
  end
end
