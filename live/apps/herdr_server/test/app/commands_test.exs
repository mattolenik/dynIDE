defmodule HerdrServer.App.CommandsTest do
  use ExUnit.Case, async: true

  alias HerdrServer.App.{Actions, Commands}
  alias HerdrServer.Layout

  defp app, do: elem(Actions.init(%{cols: 80, rows: 24}), 0)

  defp ws(app, id), do: Enum.find(app.session.workspaces, &(&1.id == id))

  defp panes(app, ws_id, tab_id) do
    ws(app, ws_id).tabs
    |> Enum.find(&(&1.id == tab_id))
    |> Map.fetch!(:layout)
    |> Layout.pane_ids()
  end

  test "create_workspace without focus keeps the active one and spawns" do
    {a, fx} = Commands.create_workspace(app(), nil, false)
    assert a.session.active_workspace == 1
    assert a.focus.pane == 1
    assert [%{id: 2, name: "2"}] = Enum.filter(a.session.workspaces, &(&1.id == 2))
    assert [{:spawn, 2, %{cols: _, rows: _}}] = fx
    assert Map.has_key?(a.session.panes, 2)
  end

  test "create_workspace with focus moves focus to the new pane" do
    {a, _} = Commands.create_workspace(app(), "dev", true)
    assert a.session.active_workspace == 2
    assert a.focus.pane == 2
    assert ws(a, 2).name == "dev"
  end

  test "split with focus? false keeps focus, with true moves it" do
    {a, [{:spawn, 2, _}]} = Commands.split_pane(app(), 1, :horizontal, 0.5, false)
    assert a.focus.pane == 1
    assert panes(a, 1, 1) == [1, 2]
    {b, _} = Commands.split_pane(app(), 1, :vertical, 0.5, true)
    assert b.focus.pane == 2
  end

  test "split in a non-active workspace changes only that workspace" do
    {a, _} = Commands.create_workspace(app(), nil, false)
    {b, [{:spawn, 3, _}]} = Commands.split_pane(a, 2, :horizontal, 0.5, true)
    assert panes(b, 2, 1) == [2, 3]
    assert panes(b, 1, 1) == [1]
    assert b.session.active_workspace == 1
    assert b.focus.pane == 1
  end

  test "split too small warns and changes nothing" do
    {a, _} = Actions.init(%{cols: 2, rows: 24})

    assert {^a, [{:notice, %{text: "pane too small to split"}}]} =
             Commands.split_pane(a, 1, :horizontal, 0.5, true)
  end

  test "close_pane in an inactive workspace, directly and via pane_exited" do
    {a, _} = Commands.create_workspace(app(), nil, false)
    {a, _} = Commands.split_pane(a, 2, :horizontal, 0.5, false)

    for step <- [&Commands.close_pane(&1, 3), &Actions.apply(&1, {:pane_exited, 3})] do
      {b, fx} = step.(a)
      assert fx == [{:close, 3}]
      assert panes(b, 2, 1) == [2]
      assert panes(b, 1, 1) == [1]
      refute Map.has_key?(b.session.panes, 3)
      assert b.focus.pane == 1
    end
  end

  test "closing the last pane of a tab closes the tab" do
    {a, _} = Commands.create_tab(app(), 1, "x", false)
    {b, fx} = Commands.close_pane(a, 2)
    assert fx == [{:close, 2}]
    assert length(ws(b, 1).tabs) == 1
    {c, fx} = Commands.close_pane(app(), 1)
    assert [{:close, 1}, {:spawn, 2, _}] = fx
    assert panes(c, 1, 1) == [2]
  end

  test "close_workspace: last is refused, others close their panes" do
    assert {a, [{:notice, %{level: :warning, text: "cannot close the last workspace"}}]} =
             Commands.close_workspace(app(), 1)

    assert a == app()
    {a, _} = Commands.create_workspace(app(), nil, true)
    {b, fx} = Commands.close_workspace(a, 2)
    assert fx == [{:close, 2}]
    assert b.session.active_workspace == 1
    assert b.focus.pane == 1
    assert length(b.session.workspaces) == 1
  end

  test "tabs: create, focus, rename, close" do
    {a, [{:spawn, 2, _}]} = Commands.create_tab(app(), 1, "x", false)
    assert ws(a, 1).active_tab == 1
    assert Enum.map(ws(a, 1).tabs, & &1.name) == ["1", "x"]
    {b, _} = Commands.focus_tab(a, 1, 2)
    assert b.focus.pane == 2
    {b, _} = Commands.rename_tab(b, 1, 2, "y")
    assert Enum.map(ws(b, 1).tabs, & &1.name) == ["1", "y"]
    {c, [{:close, 2}]} = Commands.close_tab(b, 1, 2)
    assert c.focus.pane == 1
  end

  test "focus_pane activates its workspace and tab" do
    {a, _} = Commands.create_workspace(app(), nil, false)
    {b, []} = Commands.focus_pane(a, 2)
    assert b.session.active_workspace == 2
    assert b.focus.pane == 2
  end

  test "unknown ids are no-ops" do
    a = app()
    assert {^a, []} = Commands.focus_workspace(a, 9)
    assert {^a, []} = Commands.rename_workspace(a, 9, "x")
    assert {^a, []} = Commands.close_workspace(a, 9)
    assert {^a, []} = Commands.create_tab(a, 9, nil, true)
    assert {^a, []} = Commands.focus_tab(a, 1, 9)
    assert {^a, []} = Commands.rename_tab(a, 9, 1, "x")
    assert {^a, []} = Commands.close_tab(a, 1, 9)
    assert {^a, []} = Commands.split_pane(a, 9, :horizontal, 0.5, true)
    assert {^a, []} = Commands.close_pane(a, 9)
    assert {^a, []} = Commands.focus_pane(a, 9)
    assert Commands.locate(a, 9) == nil
    assert Commands.locate(a, 1) == {1, 1}
  end
end
