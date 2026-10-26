defmodule DynideServer.App.WorkspacesTest do
  use ExUnit.Case, async: true
  alias DynideServer.App.{Actions, Keybinds, Workspaces}
  alias DynideServer.Layout

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)

  defp pfx(app, key) do
    {m, f, a} = Keybinds.lookup(app.ui.keybinds, :prefix, Keybinds.normalize(key, []))
    Kernel.apply(m, f, [app | a])
  end

  defp names(app), do: Enum.map(app.session.workspaces, & &1.name)

  test "new_workspace adds one workspace, tab and pane and spawns once" do
    {app, effects} = Actions.new_workspace(fresh())
    assert [{:spawn, 2, %{cols: 74, rows: 23}}] = effects
    assert [%{id: 1}, %{id: 2, tabs: [%{layout: l}]}] = app.session.workspaces
    assert Layout.pane_ids(l) == [2]
    assert app.session.active_workspace == 2
    assert app.focus.pane == 2
    assert Map.has_key?(app.session.panes, 2)
  end

  test "workspace names count up" do
    {app, _} = Actions.new_workspace(fresh())
    {app, _} = Actions.new_workspace(app)
    {app, _} = Actions.new_workspace(app)
    assert names(app) == ["1", "workspace", "workspace 2", "workspace 3"]
  end

  test "prefix N creates a workspace" do
    {app, [{:spawn, 2, _}]} = pfx(fresh(), "N")
    assert length(app.session.workspaces) == 2
  end

  test "switch_workspace changes active workspace and focus; out of range is a no-op" do
    {app, _} = Actions.new_workspace(fresh())
    {back, []} = Actions.switch_workspace(app, 1)
    assert back.session.active_workspace == 1
    assert back.focus.pane == 1
    assert {^back, []} = Actions.switch_workspace(back, 9)
    assert {^back, []} = Actions.switch_workspace(back, 0)
    {again, []} = Actions.switch_workspace_id(back, 2)
    assert again.focus.pane == 2
    assert {^again, []} = Actions.switch_workspace_id(again, 99)
  end

  test "next and previous wrap" do
    {app, _} = Actions.new_workspace(fresh())
    {a, []} = Actions.next_workspace(app)
    assert a.session.active_workspace == 1
    {b, []} = Actions.previous_workspace(a)
    assert b.session.active_workspace == 2
  end

  test "focus_pane switches workspace and tab" do
    {app, _} = Actions.new_tab(fresh())
    {app, _} = Actions.new_workspace(app)
    assert app.focus.pane == 3
    {app, []} = Actions.focus_pane(app, 1)
    assert app.session.active_workspace == 1
    assert hd(app.session.workspaces).active_tab == 1
    assert app.focus.pane == 1
    {app, []} = Actions.focus_pane(app, 2)
    assert hd(app.session.workspaces).active_tab == 2
    assert app.focus.pane == 2
    assert {^app, []} = Actions.focus_pane(app, 99)
  end

  test "focus_pane focuses a pane inside a split of another workspace" do
    {app, _} = pfx(fresh(), "v")
    {app, _} = Actions.new_workspace(app)
    {app, []} = Actions.focus_pane(app, 1)
    assert app.focus.pane == 1
    assert app.session.active_workspace == 1
  end

  test "close_workspace closes all its panes and activates a neighbour" do
    {app, _} = Actions.new_workspace(fresh())
    {app, _} = Actions.new_tab(app)
    {app, effects} = Actions.close_workspace(app)
    assert Enum.sort(effects) == [{:close, 2}, {:close, 3}]
    assert [%{id: 1}] = app.session.workspaces
    assert app.session.active_workspace == 1
    assert app.focus.pane == 1
    assert Map.keys(app.session.panes) == [1]
  end

  test "close_workspace/2 of an inactive workspace keeps the active one" do
    {app, _} = Workspaces.new_workspace(fresh(), "bg", false)
    assert app.session.active_workspace == 1
    {app, [{:close, 2}]} = Workspaces.close_workspace(app, 2)
    assert {app.session.active_workspace, app.focus.pane} == {1, 1}
    assert names(app) == ["1"]
    assert Workspaces.close_workspace(app, 9) == {app, []}
  end

  test "ids are not reused: close the newest workspace or tab, then create one" do
    {app, _} = Actions.new_workspace(fresh())
    {app, _} = Workspaces.close_workspace(app, 2)
    {app, _} = Actions.new_workspace(app)
    assert Enum.map(app.session.workspaces, & &1.id) == [1, 3]

    {app, _} = Actions.new_tab(app)
    [_, t] = List.last(app.session.workspaces).tabs
    {app, _} = Actions.close_tab(app, t.id)
    {app, _} = Actions.new_tab(app)
    [_, t2] = List.last(app.session.workspaces).tabs
    assert t2.id > t.id and t2.name == t.name
  end

  test "closing the last workspace replaces it with a fresh one" do
    {app, effects} = Actions.close_workspace(fresh())
    assert [{:close, 1}, {:spawn, 2, %{cols: 74, rows: 23}}] = effects
    # a fresh id: the closed workspace's id 1 is not reused
    assert [%{id: 2, name: "workspace"}] = app.session.workspaces
    assert app.focus.pane == 2
    assert Map.keys(app.session.panes) == [2]
  end

  test "renames" do
    {app, _} = Actions.new_workspace(fresh())
    {app, []} = Actions.rename_workspace(app, 2, "api")
    {app, []} = Actions.rename_tab(app, 1, 1, "logs")
    {app, []} = Actions.rename_pane(app, 2, "build")
    assert names(app) == ["1", "api"]
    assert [%{name: "logs"}] = hd(app.session.workspaces).tabs
    assert app.session.panes[2].name == "build"
    # tab ids are per workspace: only workspace 1's tab 1 was renamed
    assert [%{name: "1"}] = List.last(app.session.workspaces).tabs
    assert {^app, []} = Actions.rename_pane(app, 99, "x")
  end

  @cwd "/somewhere/proj"

  test "workspace_cwd stores the cwd and renames only auto-named workspaces" do
    {app, _} = Actions.new_workspace(fresh())
    {app, _} = Workspaces.new_workspace(app, "named", false)
    assert [%{auto_name: true}, %{auto_name: true}, %{auto_name: false}] = app.session.workspaces

    app =
      Enum.reduce([1, 2, 3], app, fn id, app ->
        elem(Actions.apply(app, {:workspace_cwd, id, @cwd, "proj"}), 0)
      end)

    assert names(app) == ["proj", "proj", "named"]
    assert Enum.all?(app.session.workspaces, &(&1.cwd == @cwd))
    # a nil label keeps the name; an unknown workspace is a no-op
    {app, []} = Actions.apply(app, {:workspace_cwd, 1, "/", nil})
    assert hd(names(app)) == "proj" and hd(app.session.workspaces).cwd == "/"
    assert {^app, []} = Actions.apply(app, {:workspace_cwd, 99, @cwd, "proj"})
  end

  test "a user rename clears auto_name" do
    {app, []} = Actions.rename_workspace(fresh(), 1, "mine")
    assert [%{name: "mine", auto_name: false}] = app.session.workspaces
    {app, []} = Actions.apply(app, {:workspace_cwd, 1, @cwd, "proj"})
    assert names(app) == ["mine"]
  end

  test "workspace_git stores the info, nil clears it, unknown is a no-op" do
    info = %{branch: "main", ahead: 1, behind: 0}
    {app, []} = Actions.apply(fresh(), {:workspace_git, 1, info})
    assert hd(app.session.workspaces).git == info
    assert {^app, []} = Actions.apply(app, {:workspace_git, 1, info})
    assert {^app, []} = Actions.apply(app, {:workspace_git, 99, nil})
    {app, []} = Actions.apply(app, {:workspace_git, 1, nil})
    assert hd(app.session.workspaces).git == nil
  end

  test "move_tab and move_workspace clamp the index and keep ids and the active one" do
    {app, _} = Actions.new_tab(fresh())
    {app, _} = Actions.new_tab(app)
    ws = fn app -> hd(app.session.workspaces) end
    tabs = fn app -> Enum.map(ws.(app).tabs, & &1.id) end
    assert ws.(app).active_tab == 3

    {moved, [{:api_event, {:tab_moved, 1, 3, 0}}]} = Workspaces.move_tab(app, 1, 3, 0)
    assert tabs.(moved) == [3, 1, 2]
    assert Workspaces.move_tab(app, 1, 3, 2) == {app, []}
    assert {_, [{:api_event, {:tab_moved, 1, 1, 3}}]} = Workspaces.move_tab(app, 1, 1, 2)
    assert ws.(moved).active_tab == 3
    assert tabs.(elem(Workspaces.move_tab(app, 1, 1, 99), 0)) == [2, 3, 1]
    assert tabs.(elem(Workspaces.move_tab(app, 1, 3, -5), 0)) == [3, 1, 2]
    assert elem(Workspaces.move_tab(app, 1, 9, 0), 0) == app
    assert elem(Workspaces.move_tab(app, 9, 1, 0), 0) == app

    {app, _} = Actions.new_workspace(app)
    {app, _} = Actions.new_workspace(app)
    ids = fn app -> Enum.map(app.session.workspaces, & &1.id) end
    {moved, [{:api_event, {:workspace_moved, 3, 0}}]} = Workspaces.move_workspace(app, 3, 0)
    assert ids.(moved) == [3, 1, 2]
    assert moved.session.active_workspace == 3
    assert ids.(elem(Workspaces.move_workspace(app, 1, 7), 0)) == [2, 3, 1]
    assert elem(Workspaces.move_workspace(app, 9, 0), 0) == app
  end
end
