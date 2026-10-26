defmodule DynideTerm.Client.Term.Render.Chrome.ToastTest do
  use ExUnit.Case, async: true

  alias DynideScene.Fixture
  alias DynideScene.Scene.Node
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Chrome
  alias DynideTerm.Client.Term.Theme

  @theme Theme.default()

  defp seg(layout, y, x) do
    {^x, _w, cells} = Enum.find(layout.top[y], &(elem(&1, 0) == x))
    Cells.to_text(cells)
  end

  test "the toast fixture: a card at the bottom-right of the panes with a hit" do
    scene = Fixture.load("toast_120x40")
    %Node{rect: r} = t = Enum.find(scene.chrome.children, &(&1.role == :toast))
    l = Chrome.layout(scene.chrome, scene.size, @theme)

    assert r.x + r.w == scene.size.cols
    assert seg(l, r.y, r.x) == "┌" <> String.duplicate("─", r.w - 2) <> "┐"
    assert seg(l, r.y + 1, r.x) == String.pad_trailing("│● " <> t.text, r.w - 1) <> "│"
    [body] = t.children
    assert seg(l, r.y + 2, r.x) == String.pad_trailing("│  " <> body.text, r.w - 1) <> "│"
    assert seg(l, r.y + 3, r.x) == "└" <> String.duplicate("─", r.w - 2) <> "┘"
    assert %{path: [{:toast, _}], role: :toast} = hd(l.hits)
  end

  test "a toast clipped to a tiny rect still draws inside it" do
    n = %Node{
      role: :toast,
      id: {:toast, 1},
      rect: %{x: 0, y: 0, w: 3, h: 2},
      text: "title",
      token: :error,
      props: %{level: :attention, pane: 1},
      children: [%Node{role: :text, id: :body, text: "body"}]
    }

    root = %Node{role: :root, id: :root, children: [n]}
    l = Chrome.layout(root, %{cols: 3, rows: 2}, @theme)
    assert Enum.all?([0, 1], &(Enum.map(l.top[&1], fn {_, w, _} -> w end) == [3]))
  end
end
