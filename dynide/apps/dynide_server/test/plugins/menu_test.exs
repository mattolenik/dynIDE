defmodule DynideServer.Plugins.MenuTest do
  use ExUnit.Case, async: false

  alias DynideServer.App.Actions
  alias DynideServer.App.Modal.Menu, as: ModalMenu
  alias DynideServer.Plugins.{Install, Keybind, Menu}
  alias DynideServer.Test.PluginDirs

  setup do
    base = PluginDirs.use_tmp()
    on_exit(fn -> Menu.put([]) end)

    PluginDirs.plugin(base <> "/p", "t.p", """
    [[actions]]
    id = "go"
    title = "Go here"
    contexts = ["pane"]
    command = ["true"]

    [[actions]]
    id = "any"
    title = "Anywhere"
    command = ["true"]
    """)

    {:ok, _} = Install.link(base <> "/p", true)
    Menu.refresh()
    %{app: elem(Actions.init(%{cols: 80, rows: 24}), 0)}
  end

  test "a pane-context action appears in the pane menu and emits a plugin invoke", %{app: app} do
    items = Menu.items(app, :pane, 1)
    assert [{{:plugin, "t.p.go"}, "Go here", {Keybind, :invoke_for, _} = mfa}] = items
    assert Menu.items(app, :tab, 1) == []
    assert [{{:plugin, "t.p.any"}, "Anywhere", _}] = Menu.items(app, :global, nil)

    {app2, []} = ModalMenu.open(app, :pane, 1, %{x: 1, y: 1})
    [menu] = app2.focus.modal
    assert List.last(menu.items) == hd(items)

    {m, f, a} = mfa

    assert {^app, [{:plugin, {:invoke, "t.p.go", %{source: "menu", target: {:pane, 1}}}}]} =
             apply(m, f, [app | a])
  end

  test "a disabled plugin has no items", %{app: app} do
    {:ok, _} = Install.set_enabled("t.p", false)
    Menu.refresh()
    assert Menu.items(app, :pane, 1) == []
  end
end
