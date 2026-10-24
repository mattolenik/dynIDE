defmodule HerdrServer.App.Modal.KeybindsTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Keybinds, Modal}
  alias HerdrServer.App.Modal.Keybinds, as: KeybindsModal
  alias HerdrServer.App.Modal.Prompt

  defp fresh, do: elem(Actions.init(%{cols: 120, rows: 40}), 0)
  defp open, do: elem(KeybindsModal.open(fresh()), 0)
  defp key(app, k, mods \\ []), do: Actions.apply(app, Event.key(k, mods))
  defp press(app, k, mods \\ []), do: elem(key(app, k, mods), 0)
  defp type(app, str), do: str |> String.graphemes() |> Enum.reduce(app, &press(&2, &1))
  defp view(app), do: Modal.view(app, app.session.size)
  defp list(app), do: Node.find(view(app), [:list]).children
  defp items(app), do: Enum.filter(list(app), &(&1.role == :item))

  defp click(app, path),
    do: Actions.apply(app, {:chrome, [{:modal, 0} | path], {:click, %{x: 0, y: 0}}})

  # filter down to one action and start capturing it
  defp capture(app, action) do
    app = app |> press("/") |> type(action) |> press(:enter)
    assert [%{id: {:action, ^action}}] = items(app)
    press(app, :enter)
  end

  test "grouped list: headings, items with keycaps, unset when unbound" do
    app = open()
    n = view(app)
    assert n.props.kind == :keybinds
    assert Node.find(n, [:title]).text == "keybinds"
    assert Node.find(n, [:subtitle]).text == "press / to filter by command or shortcut"
    headings = for %{role: :text, text: t} <- list(app), do: t
    assert headings == ["global", "navigation", "workspaces / tabs"]

    # the list shows a window of rows: narrow it to the tab actions
    app = app |> press("/") |> type("tab") |> press(:enter)
    rename = Enum.find(items(app), &(&1.id == {:action, "rename_tab"}))
    assert rename.text == "rename tab"

    assert [
             %Node{
               role: :keycap,
               text: "prefix+shift+t",
               props: %{key: "T", mods: [], prefix: true}
             }
           ] =
             rename.children

    {:ok, kb} = Keybinds.rebind(fresh().ui.keybinds, "rename_tab", "prefix+n")
    app = put_in(app.ui.keybinds, kb)
    next = Enum.find(items(app), &(&1.id == {:action, "next_tab"}))
    assert [%Node{role: :text, text: "unset", token: :muted}] = next.children
  end

  test "j/k, arrows and pgup/pgdn move the selection; the list scrolls" do
    app = open()
    assert [%{props: %{selected: true}} | _] = items(app)
    app = press(app, "j")
    assert Enum.at(items(app), 1).props.selected
    app = press(app, :page_down)
    assert Modal.top(app).selected == 11
    app = Enum.reduce(1..40, app, fn _, a -> press(a, :down) end)
    assert List.last(items(app)).props.selected
    assert Node.find(view(app), [:list]).props.offset > 0
    last = Modal.top(app).selected
    app = app |> press(:page_up) |> press("k")
    assert Modal.top(app).selected == last - 11
  end

  test "/ filters by action, label or shortcut; Esc leaves the filter" do
    app = open() |> press("/") |> type("split")

    assert Enum.map(items(app), & &1.id) == [
             {:action, "split_vertical"},
             {:action, "split_horizontal"}
           ]

    assert %Node{role: :input, text: "split"} = Node.find(view(app), [:input])
    app = press(app, :escape)
    assert %{kind: :keybinds, filter: %{text: ""}, filtering: false} = Modal.top(app)
    assert length(items(app)) > 2

    app = app |> press("/") |> type("prefix+shift+x")
    assert Enum.map(items(app), & &1.id) == [{:action, "close_tab"}]

    app = app |> press(:escape) |> press("/") |> type("zzz")
    assert items(app) == []
    assert [%Node{role: :text, text: "no matching keybinds"}] = list(app)
  end

  test "Esc closes the modal when not filtering or capturing" do
    {app, []} = key(open(), :escape)
    assert app.focus.modal == []
  end

  test "capture: ctrl+b then t rebinds rename_tab to prefix+t" do
    app = capture(open(), "rename_tab")
    assert Modal.capturing?(app.focus)
    assert Node.find(view(app), [:subtitle]).text == "press a key for rename_tab · esc cancels"

    {app, []} = key(app, "b", [:ctrl])
    assert Modal.capturing?(app.focus)
    {app, effects} = key(app, "t")
    refute Modal.capturing?(app.focus)
    assert %{kind: :keybinds} = Modal.top(app)
    assert effects == [{:config_write, ["keys"], %{"rename_tab" => ["prefix+t"]}}]
    assert Keybinds.lookup(app.ui.keybinds, :prefix, {"t", []}) == {Prompt, :rename_tab, []}
    assert Keybinds.lookup(app.ui.keybinds, :prefix, {"T", []}) == nil
  end

  test "capture: a plain key is a prefix bind, a ctrl/alt chord a direct bind" do
    {app, [{:config_write, ["keys"], %{"rename_tab" => ["prefix+y"]}}]} =
      open() |> capture("rename_tab") |> key("y")

    assert Keybinds.lookup(app.ui.keybinds, :prefix, {"y", []}) == {Prompt, :rename_tab, []}

    {app, [{:config_write, ["keys"], %{"rename_tab" => ["ctrl+t"]}}]} =
      app |> press(:enter) |> key("t", [:ctrl])

    assert Keybinds.lookup(app.ui.keybinds, :terminal, {"t", [:ctrl]}) ==
             {Prompt, :rename_tab, []}

    assert MapSet.member?(Keybinds.intercept_set(app.ui.keybinds), {"t", [:ctrl]})
  end

  test "capture Esc cancels and leaves the bindings unchanged; releases are ignored" do
    app = capture(open(), "rename_tab")
    before = app.ui.keybinds
    {app, []} = Actions.apply(app, Event.key("t", [], event: :release))
    assert Modal.capturing?(app.focus)
    {app, []} = key(app, "b", [:ctrl]) |> elem(0) |> key(:escape)
    refute Modal.capturing?(app.focus)
    assert %{kind: :keybinds} = Modal.top(app)
    assert app.ui.keybinds == before
    assert Node.find(view(app), [:subtitle]).text == "press / to filter by command or shortcut"
  end

  test "a click on a row starts capturing it" do
    {app, []} = click(open(), [:list, {:action, "new_tab"}])
    assert %{capture: true, capturing: "new_tab"} = Modal.top(app)
  end
end
