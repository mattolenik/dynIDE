defmodule DynideServer.App.ModalTest do
  use ExUnit.Case, async: true

  alias DynideScene.Event
  alias DynideScene.Scene.Node
  alias DynideServer.App.{Actions, Modal, Upgrade}
  alias DynideServer.App.Modal.{Prompt, TextField}

  # a test-only kind that ignores Esc and backdrop clicks (Task 8's onboarding does)
  defmodule Stubborn do
    @behaviour DynideServer.App.Modal.Kind

    alias DynideServer.View.Modal, as: V

    @impl true
    def key(modal, {:key, %{key: :enter}}, app), do: {:close, app, [{:notice, modal.id}]}
    def key(modal, _ev, _app), do: {:keep, modal}

    @impl true
    def chrome(modal, _path, _action, _app), do: {:keep, modal}

    @impl true
    def node(_modal, _app, size),
      do: %Node{
        role: :modal,
        rect: V.panel(size, 20, 6),
        props: %{kind: :stub}
      }

    @impl true
    def ignores_escape?(_modal), do: true
  end

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key, mods \\ []), do: Actions.apply(app, Event.key(key, mods))
  defp stub(app), do: Modal.push(app, %{kind: Stubborn})

  defp prompt(app),
    do: Modal.push(app, Prompt.new("rename tab", "", {Actions, :rename_tab, [1, 1]}))

  test "push, top and pop keep the stack top first with fresh ids" do
    app = fresh()
    assert Modal.top(app) == nil
    app = app |> prompt() |> stub()
    assert [%{kind: Stubborn, id: 2}, %{kind: :prompt, id: 1}] = app.focus.modal
    assert %{kind: Stubborn} = Modal.top(app)
    app = Modal.pop(app)
    assert %{kind: :prompt, id: 1} = Modal.top(app)
    assert Modal.pop(Modal.pop(app)).focus.modal == []
  end

  test "keys, paste and mouse with a modal open never reach a pane" do
    app = prompt(fresh())

    for ev <- [Event.key("a"), Event.key("a", [], event: :release), {:paste, "zz"}] do
      {_app, effects} = Actions.apply(app, ev)
      refute Enum.any?(effects, &(elem(&1, 0) in [:key, :paste, :mouse])), inspect(ev)
    end

    mouse = {:mouse, %{kind: :press, button: :left, x: 40, y: 5, mods: [], px: nil}}
    assert {^app, []} = Actions.apply(app, mouse)
    {app, []} = Actions.apply(app, {:paste, "zz"})
    assert Modal.top(app).field.text == "zz"
  end

  test "Esc pops the top modal only" do
    app = fresh() |> prompt() |> prompt()
    {app, []} = press(app, :escape)
    assert [%{id: 1}] = app.focus.modal
    {app, []} = press(app, :escape)
    assert app.focus.modal == []
  end

  test "a kind that ignores Esc keeps its modal; its own keys still work" do
    app = stub(fresh())
    {app, []} = press(app, :escape)
    assert [%{kind: Stubborn}] = app.focus.modal
    {app, []} = Actions.apply(app, {:chrome, [{:modal, 1}, :backdrop], {:click, %{x: 0, y: 0}}})
    assert [%{kind: Stubborn}] = app.focus.modal
    assert {%{focus: %{modal: []}}, [{:notice, 1}]} = press(app, :enter)
  end

  test "a backdrop click cancels; a stale depth or the panel itself does nothing" do
    app = prompt(fresh())
    click = {:click, %{x: 0, y: 0}}
    assert {^app, []} = Actions.apply(app, {:chrome, [{:modal, 3}, :backdrop], click})
    assert {^app, []} = Actions.apply(app, {:chrome, [{:modal, 1}], click})
    {app, []} = Actions.apply(app, {:chrome, [{:modal, 1}, :backdrop], click})
    assert app.focus.modal == []
  end

  test "bindings do not run while a modal is open, except detach" do
    app = prompt(fresh())

    for mfa <- [
          {Prompt, :new_tab, []},
          {Actions, :close_pane, []},
          {Actions, :split, [:horizontal]}
        ] do
      assert Actions.run(app, mfa) == {app, []}, inspect(mfa)
    end

    assert Actions.run(app, {Actions, :detach, []}) == {app, [{:detach}]}
    assert {_, [{:spawn, 2, _}]} = Actions.run(fresh(), {Actions, :split, [:horizontal]})
  end

  test "chrome paths beneath an open modal do nothing" do
    {app, _} = Actions.new_tab(fresh())
    app = prompt(app)

    for path <- [[:tabs, {:tab, 1}], [:tabs, :new_tab], [:sidebar, :toggle]] do
      assert Actions.apply(app, {:chrome, path, {:click, %{x: 0, y: 0}}}) == {app, []}
    end

    assert {^app, []} =
             Actions.apply(app, {:chrome, [:tabs, {:tab, 1}], {:right_click, %{x: 0, y: 0}}})
  end

  test "capturing? is true only when the top modal captures keys" do
    refute Modal.capturing?(fresh().focus)
    refute Modal.capturing?(prompt(fresh()).focus)
    app = Modal.push(fresh(), %{kind: Stubborn, capture: true})
    assert Modal.capturing?(app.focus)
    refute Modal.capturing?(prompt(app).focus)
  end

  test "view draws the top modal only, with its id in the node id" do
    assert Modal.view(fresh(), %{cols: 80, rows: 24}) == nil
    app = fresh() |> prompt() |> stub()

    assert %Node{role: :modal, id: {:modal, 2}, props: %{kind: :stub}} =
             Modal.view(app, %{cols: 80, rows: 24})
  end

  test "modal ids are monotonic: a stale click never lands on a later modal at its depth" do
    click = {:click, %{x: 0, y: 0}}
    app = prompt(fresh())
    stale = Modal.view(app, %{cols: 80, rows: 24}).id
    # closed and another opened at the same depth (another client's menu, say)
    app = app |> Modal.pop() |> prompt()
    assert [%{id: 2}] = app.focus.modal
    assert {^app, []} = Actions.apply(app, {:chrome, [stale, :backdrop], click})
    fresh_id = Modal.view(app, %{cols: 80, rows: 24}).id

    assert {%{focus: %{modal: []}}, []} =
             Actions.apply(app, {:chrome, [fresh_id, :backdrop], click})

    # the counter survives an upgrade of an old focus with a stack
    old = %{app | focus: Map.from_struct(app.focus) |> Map.delete(:next_modal_id)}
    assert [%{id: 3}, _] = Upgrade.app(old) |> stub() |> then(& &1.focus.modal)
  end

  test "modal state is plain data" do
    app = fresh() |> prompt()
    assert Modal.top(app).field == TextField.new("")
    refute inspect(app.focus.modal) =~ "#Function"
  end
end
