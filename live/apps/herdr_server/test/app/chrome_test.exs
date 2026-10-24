defmodule HerdrServer.App.ChromeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Session, Ui, Upgrade}
  alias HerdrServer.Layout
  alias HerdrServer.View.Sidebar

  # 146 cols: a 26-col sidebar leaves a 120-col pane area
  defp fresh(cols \\ 146, rows \\ 30), do: elem(Actions.init(%{cols: cols, rows: rows}), 0)
  defp at(x, y), do: %{x: x, y: y}

  defp chrome(app, path, kind, x \\ 0, y \\ 0),
    do: Actions.apply(app, {:chrome, path, {kind, at(x, y)}})

  defp ws(app), do: Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
  defp layout(app), do: Enum.find(ws(app).tabs, &(&1.id == ws(app).active_tab)).layout
  defp ratio(app), do: elem(layout(app).root, 2)

  test "tab click switches to that tab; tab bar wheel steps tabs" do
    {app, _} = Actions.new_tab(fresh())
    {app, _} = Actions.new_tab(app)
    assert ws(app).active_tab == 3

    {app, []} = chrome(app, [:tabs, {:tab, 1}], :click)
    assert ws(app).active_tab == 1
    assert app.focus.pane == 1

    {app, []} = chrome(app, [:tabs, {:tab, 2}], :scroll_down)
    assert ws(app).active_tab == 2
    {app, []} = chrome(app, [:tabs], :scroll_up)
    assert ws(app).active_tab == 1
    {app2, []} = chrome(app, [:tabs, {:tab, 99}], :click)
    assert app2 == app
  end

  test "new tab button opens a tab" do
    {app, [{:spawn, 2, _}]} = chrome(fresh(), [:tabs, :new_tab], :click)
    assert length(ws(app).tabs) == 2
  end

  test "divider drag sets the split ratio from the pointer, clamped" do
    {app, _} = Actions.split(fresh(), :horizontal)
    [%{area: area, path: []}] = Layout.splits(layout(app), app.session.area)
    assert area.w == 120

    {app, []} = chrome(app, [{:divider, []}], :drag, area.x + 30, 5)
    assert_in_delta ratio(app), 0.25, 0.01
    {app, []} = chrome(app, [{:divider, []}], :drop, area.x + 60, 5)
    assert_in_delta ratio(app), 0.5, 0.01
    {app, []} = chrome(app, [{:divider, []}], :drag, area.x + 1, 5)
    assert_in_delta ratio(app), 0.1, 0.001
    {app2, []} = chrome(app, [{:divider, [true]}], :drag, area.x + 60, 5)
    assert app2 == app
  end

  test "vertical divider drag uses the pointer row" do
    {app, _} = Actions.split(fresh(), :vertical)
    [%{area: area}] = Layout.splits(layout(app), app.session.area)
    {app, []} = chrome(app, [{:divider, []}], :drag, 40, area.y + div(area.h, 4))
    assert_in_delta ratio(app), 0.25, 0.05
  end

  test "sidebar edge drag sets the width and the pane area follows; clamped; double click resets" do
    app = fresh()
    w0 = app.session.area.w

    {app, []} = chrome(app, [:sidebar, :edge], :drag, 30, 3)
    assert app.ui.sidebar.width == 31
    assert app.session.area.w == w0 - 5

    {app, []} = chrome(app, [:sidebar, :edge], :drop, 5, 3)
    assert app.ui.sidebar.width == 18

    {app, []} = chrome(app, [:sidebar, :edge], :drag, 90, 3)
    assert app.ui.sidebar.width == 36

    {app, []} = chrome(app, [:sidebar, :edge], :double_click, 35, 3)
    assert app.ui.sidebar.width == 26
    assert app.session.area.w == w0
  end

  test "sidebar split drag sets the split ratio, clamped" do
    app = fresh()
    {app, []} = chrome(app, [:sidebar, :split], :drag, 3, 7)
    assert_in_delta app.ui.sidebar.split, 7 / 29, 0.001
    {app, []} = chrome(app, [:sidebar, :split], :drop, 3, 0)
    assert app.ui.sidebar.split == 0.1
  end

  test "sidebar toggle collapses and expands, recomputing the area" do
    app = fresh()
    {app, []} = chrome(app, [:sidebar, :toggle], :click)
    assert app.ui.sidebar.collapsed
    assert app.session.area.w == 146 - 4
    {app, []} = chrome(app, [:sidebar, :toggle], :click)
    refute app.ui.sidebar.collapsed
  end

  test "workspace click switches, new creates, agent click focuses" do
    {app, _} = Actions.new_workspace(fresh())
    assert app.session.active_workspace == 2

    {app, []} = chrome(app, [:sidebar, :spaces, :list, {:workspace, 1}], :click)
    assert app.session.active_workspace == 1

    {app, []} = chrome(app, [:sidebar, :agents, :list, {:pane, 2}], :click)
    assert app.session.active_workspace == 2
    assert app.focus.pane == 2

    {app, [{:spawn, _, _}]} = chrome(app, [:sidebar, :spaces, :new], :click)
    assert length(app.session.workspaces) == 3
  end

  test "list wheel scrolls the list offset, clamped to the items; the view carries it" do
    {app, _} = Actions.new_workspace(fresh())
    {app, _} = Actions.new_workspace(app)

    {app, []} = chrome(app, [:sidebar, :spaces, :list, {:workspace, 1}], :scroll_down)
    {app, []} = chrome(app, [:sidebar, :spaces], :scroll_down)
    {app, []} = chrome(app, [:sidebar, :spaces, :list], :scroll_down)
    assert app.ui.sidebar.spaces_offset == 2
    {app, []} = chrome(app, [:sidebar, :spaces, :list], :scroll_up)
    assert app.ui.sidebar.spaces_offset == 1

    {app, []} = chrome(app, [:sidebar, :agents, :list, {:pane, 1}], :scroll_down)
    assert app.ui.sidebar.agents_offset == 1
    {app, []} = chrome(app, [:sidebar, :agents], :scroll_up)
    {app, []} = chrome(app, [:sidebar, :agents], :scroll_up)
    assert app.ui.sidebar.agents_offset == 0

    # one owner of the skip: the view sets `offset`, the client skips that many items
    sb = Sidebar.node(app, %{x: 0, y: 0, w: 26, h: 29})
    assert %Node{props: %{offset: 1}, children: [_, _, _]} = Node.find(sb, [:spaces, :list])
    assert %Node{props: %{offset: 0}} = Node.find(sb, [:agents, :list])
  end

  test "modal, menu and unknown paths are no-ops" do
    app = fresh()

    for path <- [[{:modal, 0}, :actions, :ok], [{:menu, 0}, {:entry, :x}], [:status], [:nope]],
        kind <- [:click, :drag, :scroll_up],
        do: assert(chrome(app, path, kind) == {app, []})
  end

  test "an old sidebar map gains the offsets on upgrade" do
    ui = %{%Ui{} | sidebar: %{visible: true, collapsed: false, width: 30}, keybinds: nil}
    app = Upgrade.app(%{session: %Session{}, focus: %{}, ui: ui})
    assert %{spaces_offset: 0, agents_offset: 0, width: 30} = app.ui.sidebar
  end
end
