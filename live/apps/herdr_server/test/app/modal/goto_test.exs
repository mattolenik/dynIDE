defmodule HerdrServer.App.Modal.GotoTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers, only: [pfx: 2, add_workspace: 2]

  alias HerdrScene.Event
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Modal}

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 30}), 0)
  defp press(app, key, mods \\ []), do: elem(Actions.apply(app, Event.key(key, mods)), 0)
  defp type(app, text), do: Enum.reduce(String.graphemes(text), app, &press(&2, &1))
  defp list(app), do: Node.find(Modal.view(app, app.session.size), [:list]).children
  defp ids(app), do: Enum.map(list(app), &elem(&1.id, 1))
  defp title(app), do: Node.find(Modal.view(app, app.session.size), [:title]).text

  # `two/0` with agent states: pane 1 idle, 2 blocked, 3 done; plus pane 4 (in "two",
  # unknown state) and the states given in `extra`
  defp agents(extra \\ %{}) do
    app = two() |> pfx("v")

    Enum.reduce(Map.merge(%{1 => :idle, 2 => :blocked, 3 => :done}, extra), app, fn {id, s}, a ->
      put_in(a.session.panes[id][:agent_state], s)
    end)
  end

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

  test "panes closing under the selection clamp it to the last row" do
    app = pfx(two(), "g") |> press(:down) |> press(:down)
    assert Modal.top(app).selected == 2
    app = update_in(app.session.workspaces, &Enum.take(&1, 1))

    assert [%{props: %{selected: false}}, %{id: {:pane, 2}, props: %{selected: true}}] = list(app)
    assert Modal.top(press(app, :up)).selected == 0
    assert (app |> press(:enter)).focus.pane == 2
  end

  test "Enter on a pane hidden by a zoom focuses it and clears the zoom" do
    app = fresh() |> pfx("v") |> pfx("z")
    ws = hd(app.session.workspaces)
    assert Map.get(hd(ws.tabs), :zoom) == 2

    app = app |> pfx("g") |> press(:enter)
    assert app.focus.pane == 1
    refute Map.has_key?(hd(hd(app.session.workspaces).tabs), :zoom)
  end

  test "Tab cycles the status filter both ways, resetting the selection, kept text" do
    app = agents() |> pfx("g") |> type("1") |> press(:down)
    assert Modal.top(app).selected == 1

    steps = Enum.scan(1..5, app, fn _, a -> press(a, :tab) end)
    assert Enum.map(steps, &Modal.top(&1).filter) == [:blocked, :working, :idle, :done, nil]
    assert Enum.all?(steps, &(Modal.top(&1).selected == 0 and Modal.top(&1).field.text == "1"))
    assert Modal.top(press(app, :tab, [:shift])).filter == :done
    assert title(hd(steps)) == "go to / blocked" and title(app) == "go to"

    hint = Node.find(Modal.view(app, app.session.size), [:hint]).text
    assert hint =~ "tab filter"
  end

  test "blocked and done filters list only matching panes; unknown never matches" do
    app = agents() |> pfx("g")
    assert ids(press(app, :tab)) == [2]
    assert ids(app |> press(:tab, [:shift])) == [3]
    assert [%{id: :empty}] = list(app |> press(:tab) |> press(:tab))
  end

  test "filter and typed text combine" do
    app = agents(%{4 => :blocked}) |> pfx("g") |> press(:tab)
    assert ids(app) == [2, 4]
    assert ids(type(app, "two")) == [4]
    assert ids(type(app, "build")) == [2]
  end

  test "agent_panel_sort :priority orders rows by attention, stable within one" do
    app = agents(%{4 => :working})
    assert ids(pfx(app, "g")) == [1, 2, 3, 4]
    app = put_in(app.ui.agent_panel_sort, :priority) |> pfx("g")
    assert ids(app) == [2, 3, 4, 1]
  end

  test "Enter on a filtered row focuses that pane" do
    app = agents(%{4 => :blocked}) |> pfx("g") |> press(:tab) |> press(:down)
    done = press(app, :enter)
    assert done.focus.modal == [] and done.focus.pane == 4
  end

  test "an open goto modal without the filter key still works" do
    app = agents() |> pfx("g")
    app = update_in(app.focus.modal, fn [m | rest] -> [Map.delete(m, :filter) | rest] end)
    assert ids(app) == [1, 2, 3, 4]
    assert ids(press(app, :tab)) == [2]
  end
end
