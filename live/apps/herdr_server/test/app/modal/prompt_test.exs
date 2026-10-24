defmodule HerdrServer.App.Modal.PromptTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Modal}
  alias HerdrServer.App.Modal.Prompt

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key, mods \\ []), do: elem(Actions.apply(app, Event.key(key, mods)), 0)
  defp ws(app), do: Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
  defp tab_names(app), do: Enum.map(ws(app).tabs, & &1.name)

  defp click(app, id),
    do: Actions.apply(app, {:chrome, [{:modal, 0}, :actions, id], {:click, %{x: 0, y: 0}}})

  test "typing abc, backspace, ctrl+c clears, then Enter renames the tab to ab" do
    {app, []} = Prompt.rename_tab(fresh())
    assert %{kind: :prompt, title: "rename tab", field: %{text: "1"}} = Modal.top(app)
    app = press(app, "c", [:ctrl])
    app = Enum.reduce(["a", "b", "c", :backspace], app, &press(&2, &1))
    assert Modal.top(app).field == %{text: "ab", cursor: 2}
    {app, []} = Actions.apply(app, Event.key(:enter))
    assert app.focus.modal == []
    assert tab_names(app) == ["ab"]
  end

  test "submit trims whitespace and refuses an empty name" do
    {app, []} = Prompt.rename_tab(fresh())

    app =
      Enum.reduce([{"c", [:ctrl]}, {" ", []}, {" ", []}], app, fn {k, m}, a -> press(a, k, m) end)

    app = press(app, :enter)
    assert [%{kind: :prompt}] = app.focus.modal
    app = Enum.reduce(["x", " "], app, &press(&2, &1))
    app = press(app, :enter)
    assert app.focus.modal == [] and tab_names(app) == ["x"]
  end

  test "buttons: save submits, clear empties, cancel closes" do
    {app, []} = Prompt.rename_workspace(fresh())
    assert Modal.top(app).title == "rename workspace"
    {app, []} = click(app, :clear)
    assert Modal.top(app).field.text == ""
    app = press(app, "w")
    {app, []} = click(app, :save)
    assert ws(app).name == "w"
    {app, []} = Prompt.rename_pane(app)
    assert Modal.top(app).title == "rename pane"
    {app, []} = click(app, :cancel)
    assert app.focus.modal == [] and app.session.panes[1][:name] == nil
  end

  test "rename pane stores the name" do
    {app, []} = Prompt.rename_pane(fresh())
    app = Enum.reduce(["o", "k", :enter], app, &press(&2, &1))
    assert app.session.panes[1].name == "ok"
  end

  test "new tab prompts with the next tab number when prompt_new_tab_name, else creates" do
    {app, []} = Prompt.new_tab(fresh())
    assert %{title: "new tab", field: %{text: "2"}} = Modal.top(app)
    app = Enum.reduce([:backspace, "w", "e", "b"], app, &press(&2, &1))
    {app, [{:spawn, 2, _}]} = Actions.apply(app, Event.key(:enter))
    assert tab_names(app) == ["1", "web"] and ws(app).active_tab == 2

    off = put_in(fresh().ui.prompt_new_tab_name, false)
    {app, [{:spawn, 2, _}]} = Prompt.new_tab(off)
    assert app.focus.modal == [] and tab_names(app) == ["1", "2"]
  end

  test "node: title, input with cursor, save/clear/cancel buttons with keys; dims" do
    {app, []} = Prompt.rename_tab(fresh())
    node = Modal.view(app, %{cols: 80, rows: 24})
    assert %Node{role: :modal, id: {:modal, 0}, rect: %{x: 12, y: 8, w: 56, h: 7}} = node
    assert node.props == %{kind: :prompt, tone: :default, dim: true}
    assert %Node{text: "rename tab"} = Node.find(node, [:title])
    assert %Node{role: :input, text: "1", props: %{cursor: 1}} = Node.find(node, [:input])
    buttons = Node.find(node, [:actions]).children

    assert Enum.map(buttons, &{&1.id, &1.text, &1.props.key, &1.props.mods, &1.props.primary}) ==
             [
               {:save, "save", :enter, [], true},
               {:clear, "clear", "c", [:ctrl], false},
               {:cancel, "cancel", :escape, [], false}
             ]
  end
end
