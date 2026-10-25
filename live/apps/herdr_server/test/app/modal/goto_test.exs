defmodule HerdrServer.App.Modal.GotoTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers, only: [pfx: 2, add_workspace: 2]

  alias HerdrScene.Event
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Modal}

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 30}), 0)
  defp press(app, key), do: elem(Actions.apply(app, Event.key(key)), 0)
  defp type(app, text), do: Enum.reduce(String.graphemes(text), app, &press(&2, &1))
  defp list(app), do: Node.find(Modal.view(app, app.session.size), [:list]).children

  # two workspaces: "1" with panes 1 and 2 (named "build"), "two" with pane 3 (focused)
  defp two do
    app = pfx(fresh(), "v")
    app = put_in(app.session.panes[2][:name], "build")
    add_workspace(app, "two")
  end

  test "prefix g lists every pane grouped by workspace, the focused one current" do
    app = pfx(two(), "g")
    assert %{kind: :goto, selected: 0} = Modal.top(app)
    assert %Node{role: :modal, props: %{kind: :goto}} = Modal.view(app, app.session.size)

    assert [
             %{
               id: {:pane, 1},
               text: "1 · 1 · terminal",
               props: %{selected: true, current: false}
             },
             %{id: {:pane, 2}, text: "1 · 1 · build", props: %{selected: false}},
             %{id: {:pane, 3}, text: "two · 1 · terminal", props: %{current: true}}
           ] = list(app)
  end

  test "typing filters case-insensitively; no match shows the empty text" do
    app = pfx(two(), "g")
    assert [%{id: {:pane, 2}}] = list(type(app, "BuI"))
    assert [%{id: {:pane, 3}}] = list(type(app, "two"))
    assert [%{role: :text, id: :empty}] = list(type(app, "zzz"))
    assert Modal.top(type(app, "zzz") |> press(:enter)).kind == :goto
  end

  test "Enter focuses the selected pane across workspaces and closes; Down wraps" do
    app = pfx(two(), "g")
    assert app.session.active_workspace == 2

    done = app |> press(:down) |> press(:enter)
    assert done.focus.modal == []
    assert done.session.active_workspace == 1 and done.focus.pane == 2

    assert Modal.top(app |> press(:up)).selected == 2
    assert (app |> type("build") |> press(:enter)).focus.pane == 2
  end

  test "a click on a row focuses it; Esc closes with the focus unchanged" do
    app = pfx(two(), "g")
    id = Modal.top(app).id

    {clicked, _} =
      Actions.apply(app, {:chrome, [{:modal, id}, :list, {:pane, 1}], {:click, %{x: 0, y: 0}}})

    assert clicked.focus.modal == [] and clicked.focus.pane == 1

    closed = press(app, :escape)
    assert closed.focus.modal == [] and closed.focus.pane == 3
    assert closed.session.active_workspace == 2
  end
end
