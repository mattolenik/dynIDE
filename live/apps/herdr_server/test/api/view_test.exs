defmodule HerdrServer.Api.ViewTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Api.{Spec, View}
  alias HerdrServer.App.{Actions, Commands}
  alias HerdrServer.View.Frame

  defp app, do: elem(Actions.init(%{cols: 80, rows: 24}), 0)

  # the pane area of the frame (M13 sidebar, tab bar and status row)
  defp area(app), do: Frame.regions(%{cols: 80, rows: 24}, app.ui).panes

  defp stringify(map), do: map |> JSON.encode!() |> JSON.decode!()

  test "workspace, tab and pane objects match the spec" do
    app = app()
    [ws] = app.session.workspaces
    [tab] = ws.tabs

    result = %{
      "type" => "workspace_created",
      "workspace" => stringify(View.workspace(app, ws)),
      "tab" => stringify(View.tab(app, ws, tab)),
      "root_pane" => stringify(View.pane(app, 1))
    }

    assert Spec.validate_result("workspace.create", result) == :ok
    assert result["workspace"]["focused"] and result["tab"]["focused"]
    assert result["root_pane"] == stringify(View.pane(app, 1))
    %{w: w, h: h} = area(app)
    assert %{"cols" => ^w, "rows" => ^h, "focused" => true, "title" => nil} = result["root_pane"]
  end

  test "pane sizes follow the layout and focus follows the layout" do
    {app, _} = Commands.split_pane(app(), 1, :horizontal, 0.5, true)
    %{w: w, h: h} = area(app)
    rows = h - 2
    assert %{cols: c1, rows: ^rows, focused: false} = View.pane(app, 1)
    assert %{cols: c2, focused: true} = View.pane(app, 2)
    assert c1 + c2 == w - 4
    assert View.pane(app, 99) == nil
  end

  test "layout is the split tree with public ids" do
    {app, _} = Commands.split_pane(app(), 1, :vertical, 0.25, false)
    [ws] = app.session.workspaces
    [tab] = ws.tabs

    assert %{
             focused_pane_id: "p1",
             root: %{
               type: "split",
               direction: "down",
               ratio: 0.25,
               first: %{type: "pane", pane_id: "p1"},
               second: %{type: "pane", pane_id: "p2"}
             }
           } = View.layout(app, ws, tab)

    result = %{"type" => "pane_layout", "layout" => stringify(View.layout(app, ws, tab))}
    assert Spec.validate_result("pane.layout", result) == :ok
  end

  test "an unfocused workspace has unfocused tabs and panes" do
    {app, _} = Commands.create_workspace(app(), "two", false)
    [w1, w2] = app.session.workspaces
    refute View.workspace(app, w2).focused
    refute View.tab(app, w2, hd(w2.tabs)).focused
    refute View.pane(app, 2).focused
    assert View.workspace(app, w1).focused
  end

  test "title comes from pane metadata" do
    {app, _} = Actions.apply(app(), {:pane_title, 1, "vim"})
    assert View.pane(app, 1).title == "vim"
  end
end
