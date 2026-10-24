defmodule HerdrServer.App.Modal.ConfirmTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers, only: [pfx: 2]

  alias HerdrScene.Event
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Modal}
  alias HerdrServer.App.Modal.Confirm

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key), do: Actions.apply(app, Event.key(key))
  defp ws(app), do: Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))

  test "close_workspace on the last pane opens a confirm; confirm closes it" do
    {app, []} = Confirm.close_workspace(fresh())

    assert %{kind: :confirm, title: "Close workspace?", detail: "1 — 1 pane", tone: :danger} =
             Modal.top(app)

    {app, effects} = press(app, :enter)
    assert app.focus.modal == []
    assert {:close, 1} in effects
    assert [%{name: "workspace"}] = app.session.workspaces
  end

  test "cancel keeps the workspace (Esc or the cancel button)" do
    {app0, []} = Confirm.close_workspace(fresh())
    {app, []} = press(app0, :escape)
    assert app.focus.modal == [] and app.session == fresh().session

    click = {:click, %{x: 0, y: 0}}
    {app, []} = Actions.apply(app0, {:chrome, [{:modal, 0}, :actions, :cancel], click})
    assert app.focus.modal == [] and app.session == fresh().session
    {_app, effects} = Actions.apply(app0, {:chrome, [{:modal, 0}, :actions, :confirm], click})
    assert {:close, 1} in effects
  end

  test "detail counts every pane of the workspace" do
    app = pfx(fresh(), "v") |> Actions.new_tab() |> elem(0)
    {app, []} = Confirm.close_workspace(app)
    assert Modal.top(app).detail == "1 — 3 panes"
  end

  test "keybinds X, x and D confirm only when the whole workspace would go" do
    # x on the last pane of the last tab, X on the last tab, D always
    for key <- ["x", "X", "D"] do
      app = pfx(fresh(), key)
      assert [%{kind: :confirm, title: "Close workspace?"}] = app.focus.modal, key
    end

    # x with two panes, X with two tabs: direct
    app = pfx(fresh(), "v")
    assert pfx(app, "x").focus.modal == []
    assert length(Map.keys(pfx(app, "x").session.panes)) == 1
    app = Actions.new_tab(fresh()) |> elem(0)
    assert pfx(app, "X").focus.modal == []
    assert length(ws(pfx(app, "X")).tabs) == 1
  end

  test "confirm_close false closes directly" do
    app = put_in(fresh().ui.confirm_close, false)
    {app, effects} = Confirm.close_workspace(app)
    assert app.focus.modal == [] and {:close, 1} in effects
    {app, effects} = Confirm.close_pane(app)
    assert app.focus.modal == [] and match?([{:close, _}, {:spawn, _, _}], effects)
  end

  test "node: danger tone, title and detail lines, confirm and cancel buttons" do
    {app, []} = Confirm.close_workspace(fresh())
    node = Modal.view(app, %{cols: 80, rows: 24})
    assert %Node{rect: %{x: 8, y: 9, w: 64, h: 6}} = node
    assert node.props == %{kind: :confirm, tone: :danger, dim: true}
    assert Node.find(node, [:title]).text == "Close workspace?"
    assert Node.find(node, [{:line, 0}]).text == "1 — 1 pane"

    assert [
             %{id: :confirm, text: "confirm", props: %{key: :enter, primary: true}},
             %{id: :cancel, text: "cancel", props: %{key: :escape, primary: false}}
           ] =
             Node.find(node, [:actions]).children
  end
end
