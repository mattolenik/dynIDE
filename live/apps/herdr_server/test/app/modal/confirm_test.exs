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

  test "confirm_close only decides whether to ask: the last pane closes its workspace either way" do
    two = elem(Actions.new_workspace(fresh()), 0)
    assert two.session.active_workspace == 2

    for key <- ["x", "X", "D"] do
      off = pfx(put_in(two.ui.confirm_close, false), key)
      assert off.focus.modal == [], key
      on = pfx(two, key)
      {on, _} = press(on, :enter)

      for app <- [off, on] do
        assert Enum.map(app.session.workspaces, & &1.id) == [1], key
        assert app.session.active_workspace == 1
      end
    end

    # the only workspace: replaced by a fresh one, with or without asking
    {app, effects} = Confirm.close_pane(put_in(fresh().ui.confirm_close, false))
    assert app.focus.modal == []
    assert [%{name: "workspace"}] = app.session.workspaces
    assert {:close, 1} in effects
  end

  test "a pane of another workspace closes there; the active workspace stays" do
    {app, _} = Actions.new_workspace(fresh())
    app = pfx(app, "v")
    {app, _} = Actions.switch_workspace(app, 1)
    # pane 3 is workspace 2's second pane: closed directly, workspace 1 stays active
    {app2, [{:close, 3}]} = Confirm.close_pane(app, 3)
    assert app2.session.active_workspace == 1 and app2.focus.pane == 1
    assert Map.keys(app2.session.panes) == [1, 2]
    # pane 2 is now workspace 2's last pane: confirming removes workspace 2 only
    {app2, []} = Confirm.close_pane(app2, 2)
    assert Modal.top(app2).detail == "workspace — 1 pane"
    {app2, effects} = press(app2, :enter)
    assert effects == [{:close, 2}]
    assert Enum.map(app2.session.workspaces, & &1.id) == [1]
    assert app2.session.active_workspace == 1 and app2.focus.pane == 1
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
