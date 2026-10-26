defmodule DynideServer.App.Modal.OnboardingTest do
  use ExUnit.Case, async: true

  alias DynideScene.Event
  alias DynideScene.Scene.Node
  alias DynideServer.App.{Actions, Modal}
  alias DynideServer.App.Modal.Onboarding

  defp fresh, do: elem(Actions.init(%{cols: 80, rows: 24}), 0)
  defp open, do: Onboarding.at_start(put_in(fresh().ui.onboarding, true))
  defp key(app, k, mods \\ []), do: Actions.apply(app, Event.key(k, mods))

  @done [{:config_write, [], %{"onboarding" => false}}]

  test "opens at start only when ui.onboarding is set" do
    assert fresh().focus.modal == []
    assert Onboarding.at_start(fresh()).focus.modal == []
    assert [%{kind: :onboarding}] = open().focus.modal
  end

  test "Enter, Right and l continue: closes, clears ui.onboarding and writes the config" do
    for k <- [:enter, :right, "l"] do
      {app, effects} = key(open(), k)
      assert app.focus.modal == [], inspect(k)
      assert app.ui.onboarding == false
      assert effects == @done
    end

    {app, effects} =
      Actions.apply(
        open(),
        {:chrome, [{:modal, 1}, :actions, :continue], {:click, %{x: 0, y: 0}}}
      )

    assert app.focus.modal == [] and effects == @done
  end

  test "Esc, other keys and backdrop clicks do nothing" do
    app = open()
    assert {^app, []} = key(app, :escape)
    assert {^app, []} = key(app, "x")

    assert {^app, []} =
             Actions.apply(app, {:chrome, [{:modal, 1}, :backdrop], {:click, %{x: 0, y: 0}}})
  end

  test "lines: dynide title, herdr's text, the prefix from the keybinds" do
    n = Modal.view(open(), %{cols: 80, rows: 24})
    assert n.props.kind == :onboarding
    assert n.rect.w == 64 and n.rect.h == 16
    assert Node.find(n, [:title]).text == "dynIDE"
    assert Node.find(n, [:subtitle]).text == "terminal workspace manager for coding agents"

    assert Enum.map(0..2, &Node.find(n, [{:line, &1}]).text) == [
             "this is a mouse-first terminal.",
             "click the sidebar to switch workspaces, drag pane",
             "borders to resize, right-click for context menus."
           ]

    keys = Node.find(n, [{:line, 3}]).children

    assert Enum.map(keys, & &1.text) == [
             "ctrl+b",
             " enters prefix mode · ",
             "?",
             " shows keybinds and settings"
           ]

    assert [%{role: :keycap, props: %{key: "b", mods: [:ctrl]}} | _] = keys

    assert Node.find(n, [{:line, 4}]).text ==
             "next: install optional agent integrations for more reliable state"

    assert [%{id: :continue, text: "continue", props: %{key: :enter}}] =
             Node.find(n, [:actions]).children
  end
end
