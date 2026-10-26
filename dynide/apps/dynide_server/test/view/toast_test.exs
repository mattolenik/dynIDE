defmodule DynideServer.View.ToastTest do
  use ExUnit.Case, async: true

  alias DynideScene.Scene
  alias DynideScene.Scene.Node
  alias DynideServer.Client.State
  alias DynideServer.View
  alias DynideServer.View.Frame
  alias DynideServer.ViewHelpers

  defp toast(id, title, level \\ :attention),
    do: %{id: id, level: level, title: title, body: "w · 1", pane: 1}

  defp scene(toasts, {c, r} \\ {120, 40}) do
    client = %State{size: %{cols: c, rows: r}, transport: :ref, toasts: toasts}
    View.compute(ViewHelpers.fresh(c, r), client)
  end

  test "toasts sit bottom-right of the pane area, newest lowest, stacked upward" do
    s = scene([toast(2, "newer one"), toast(1, "old", :done)])
    assert Scene.validate(s) == :ok
    area = Frame.regions(s.size, ViewHelpers.fresh(120, 40).ui).panes
    newer = Node.find(s.chrome, [{:toast, 2}])
    old = Node.find(s.chrome, [{:toast, 1}])

    assert %Node{
             role: :toast,
             text: "newer one",
             token: :error,
             props: %{level: :attention, pane: 1},
             children: [%Node{role: :text, id: :body, text: "w · 1"}]
           } = newer

    assert newer.rect == %{x: area.x + area.w - 15, y: area.y + area.h - 4, w: 15, h: 4}
    assert old.rect == %{x: area.x + area.w - 11, y: area.y + area.h - 8, w: 11, h: 4}
    assert old.token == :info
  end

  test "toasts come before a modal and after the status; tiny sizes still validate" do
    s = scene([toast(1, "t")])
    roles = Enum.map(s.chrome.children, & &1.role)
    assert Enum.take(roles, -2) == [:status, :toast]

    for {c, r} <- [{20, 5}, {1, 1}, {8, 3}] do
      assert Scene.validate(scene([toast(1, "a long title for a tiny terminal")], {c, r})) == :ok
    end
  end

  test "the root carries the sound and toast delivery prefs" do
    assert %{sound: %{enabled: true, command: nil}, toast: %{delivery: :herdr}} =
             scene([]).chrome.props
  end
end
