defmodule DynideServer.App.Modal.MenuTest do
  use ExUnit.Case, async: true

  import DynideServer.ViewHelpers, only: [pfx: 2]

  alias DynideScene.Event
  alias DynideScene.Scene.Node
  alias DynideServer.App.{Actions, Modal}
  alias DynideServer.Layout

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key), do: elem(Actions.apply(app, Event.key(key)), 0)
  defp ws(app), do: Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
  defp labels(app), do: Enum.map(Modal.top(app).items, &elem(&1, 1))

  defp chrome(app, path, kind, x \\ 0, y \\ 0),
    do: Actions.apply(app, {:chrome, path, {kind, %{x: x, y: y}}})

  defp layout(app), do: Enum.find(ws(app).tabs, &(&1.id == ws(app).active_tab)).layout

  test "right click on tab 2 opens a tab menu at the click; Down, Down, Enter closes tab 2" do
    app = Actions.new_tab(fresh()) |> elem(0) |> Actions.new_tab() |> elem(0)
    {app, []} = chrome(app, [:tabs, {:tab, 2}], :right_click, 40, 0)

    assert %{kind: :menu, menu: :tab, target: 2, at: %{x: 40, y: 0}, selected: 0} =
             Modal.top(app)

    assert labels(app) == ["New tab", "Rename", "Close"]
    app = app |> press(:down) |> press(:down)
    {app, effects} = Actions.apply(app, Event.key(:enter))
    assert app.focus.modal == []
    assert Enum.map(ws(app).tabs, & &1.id) == [1, 3]
    assert effects == [{:close, 2}]
  end

  test "Up wraps, Esc closes, clicking an entry runs it, a backdrop click closes" do
    {app, []} = chrome(fresh(), [:tabs, {:tab, 1}], :right_click)
    assert Modal.top(press(app, :up)).selected == 2
    assert press(app, :escape).focus.modal == []
    assert elem(chrome(app, [{:menu, 1}, :backdrop], :click), 0).focus.modal == []

    {app, []} = chrome(app, [{:menu, 1}, {:entry, :rename}], :click)
    assert [%{kind: :prompt, title: "rename tab"}] = app.focus.modal
  end

  test "workspace and pane menus, with Clear pane name only when named" do
    {app, []} = chrome(fresh(), [:sidebar, :spaces, :list, {:workspace, 1}], :right_click)
    assert labels(app) == ["Rename", "Close"]

    {app, []} = chrome(fresh(), [:sidebar, :agents, :list, {:pane, 1}], :right_click)
    assert labels(app) == ["Rename pane", "Split right", "Split down", "Close pane"]

    {named, []} = Actions.rename_pane(pfx(fresh(), "v"), 1, "db")
    {app, []} = chrome(named, [:sidebar, :agents, :list, {:pane, 1}], :right_click)

    assert labels(app) == [
             "Rename pane",
             "Clear pane name",
             "Swap with focused pane",
             "Split right",
             "Split down",
             "Close pane"
           ]

    {app, []} = chrome(app, [{:menu, 1}, {:entry, :clear_name}], :click)
    refute app.session.panes[1][:name]
  end

  test "pane menu Close pane closes a pane of another workspace" do
    {app, _} = Actions.new_workspace(fresh())
    app = pfx(app, "v")
    {app, _} = Actions.switch_workspace(app, 1)
    {app, []} = chrome(app, [:sidebar, :agents, :list, {:pane, 3}], :right_click)
    {app, [{:close, 3}]} = chrome(app, [{:menu, 1}, {:entry, :close}], :click)
    refute Map.has_key?(app.session.panes, 3)
    assert app.session.active_workspace == 1
  end

  test "tab menu entries carry the workspace id with the tab id" do
    {app, []} = chrome(fresh(), [:tabs, {:tab, 1}], :right_click)
    [_, {:rename, _, {_, _, [1, 1]}}, {:close, _, {_, _, [1, 1]}}] = Modal.top(app).items
  end

  test "pane menu split and swap act on the target pane" do
    app = pfx(fresh(), "v")
    assert Layout.pane_ids(layout(app)) == [1, 2] and app.focus.pane == 2
    {app, []} = chrome(app, [:sidebar, :agents, :list, {:pane, 1}], :right_click)
    {swapped, []} = chrome(app, [{:menu, 1}, {:entry, :swap}], :click)
    assert Layout.pane_ids(layout(swapped)) == [2, 1]
    {split, [{:spawn, 3, _}]} = chrome(app, [{:menu, 1}, {:entry, :split_down}], :click)
    assert Layout.pane_ids(layout(split)) == [1, 3, 2]
  end

  test "global menu from the sidebar menu button lists the landed items" do
    {app, []} = chrome(fresh(), [:sidebar, :spaces, :menu], :click, 20, 10)
    assert %{menu: :global, at: %{x: 20, y: 10}} = Modal.top(app)
    assert labels(app) == ["settings", "keybinds", "reload config", "detach"]
    assert {_, [{:detach}]} = chrome(app, [{:menu, 1}, {:entry, :detach}], :click)
    {opened, []} = Actions.apply(app, Event.key(:enter))
    assert [%{kind: :settings}] = opened.focus.modal
    {opened, []} = chrome(app, [{:menu, 1}, {:entry, :keybinds}], :click)
    assert [%{kind: :keybinds}] = opened.focus.modal
  end

  test "node: a menu region at the click, clamped on screen, entries with a selection" do
    {app, []} = chrome(fresh(), [:tabs, {:tab, 1}], :right_click, 75, 22)
    node = Modal.view(app, %{cols: 80, rows: 24})
    assert %Node{role: :menu, id: {:menu, 1}, rect: %{x: 66, y: 19, w: 14, h: 5}} = node
    assert node.props == %{kind: :tab, selected: 0}

    assert [{{:entry, :new_tab}, "New tab", true}, {{:entry, :rename}, "Rename", false}, _] =
             Enum.map(node.children, &{&1.id, &1.text, &1.props.selected})
  end
end
