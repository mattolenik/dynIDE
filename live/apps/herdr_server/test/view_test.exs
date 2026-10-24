defmodule HerdrServer.ViewTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Actions
  alias HerdrServer.Client.State
  alias HerdrServer.View

  defp client(c, r, transport \\ :ref),
    do: %State{size: %{cols: c, rows: r}, transport: transport}

  defp status(scene), do: Node.find(scene.chrome, [:status])
  defp child(scene, id), do: Node.find(scene.chrome, [:status, id])

  test "single pane" do
    s = View.compute(fresh(80, 24), client(80, 24))
    assert :ok = Scene.validate(s)

    assert [%{id: 1, rect: %{x: 0, y: 0, w: 80, h: 23}, border: nil, rows: {:ref, 1, 0}}] =
             s.panes

    assert status(s).rect == %{x: 0, y: 23, w: 80, h: 1}
    assert s.focus == %{pane: 1, chrome: nil}
    assert child(s, :hint).text == "ctrl+b"
  end

  test "two panes side by side" do
    s = View.compute(pfx(fresh(120, 40), "v"), client(120, 40))
    assert :ok = Scene.validate(s)
    assert [%{rect: %{x: 1, y: 1, w: 58, h: 37}}, %{rect: %{x: 61, y: 1, w: 58, h: 37}}] = s.panes
    assert [%{border: %{rect: %{x: 0, w: 60}}}, _] = s.panes
    assert [%Node{id: {:divider, []}, rect: %{x: 60, y: 0, w: 1, h: 39}}] = tl(s.chrome.children)
  end

  test "per-client rects, same pane ids" do
    app = pfx(fresh(120, 40), "v")
    a = View.compute(app, client(80, 24))
    b = View.compute(app, client(200, 50))
    assert Enum.map(a.panes, & &1.id) == Enum.map(b.panes, & &1.id)
    refute Enum.map(a.panes, & &1.rect) == Enum.map(b.panes, & &1.rect)
  end

  test "inline transport" do
    s = View.compute(fresh(80, 24), client(80, 24, :inline))
    assert [%{rows: {:inline, []}}] = s.panes
  end

  test "mode and hint follow focus mode" do
    app = keys(fresh(80, 24), [{"b", [:ctrl]}])
    s = View.compute(app, client(80, 24))
    assert %{text: "PREFIX", token: :accent} = child(s, :mode)
    s = View.compute(pfx(fresh(80, 24), "r"), client(80, 24))
    assert %{text: "RESIZE", token: :warning} = child(s, :mode)
    assert child(s, :hint).text == ""
  end

  test "tabs mark the active one" do
    s = View.compute(pfx(fresh(80, 24), "c"), client(80, 24))
    tabs = child(s, :tabs).children
    assert [%{props: %{index: 1, active: false}}, %{props: %{index: 2, active: true}}] = tabs
    assert s.focus.pane == 2
  end

  test "pane title feeds the title node and border" do
    {app, _} = Actions.apply(pfx(fresh(80, 24), "v"), {:pane_title, 2, "vim"})
    s = View.compute(app, client(80, 24))
    assert child(s, :title).text == "vim"
    assert Enum.at(s.panes, 1).border.title == "vim"
  end

  test "chrome carries no colours or long binaries" do
    s = View.compute(pfx(pfx(fresh(100, 30), "v"), "-"), client(100, 30))
    assert Enum.all?(walk(s.chrome), &plain?/1)
  end

  defp walk(%Node{} = n), do: [n.props | Enum.flat_map(n.children, &walk/1)]
  defp plain?(props), do: props |> Map.values() |> Enum.all?(&plain_value?/1)
  defp plain_value?(v) when is_atom(v) or is_boolean(v), do: true
  defp plain_value?(v) when is_integer(v), do: v in 0..10_000
  defp plain_value?(v) when is_binary(v), do: byte_size(v) < 64
  defp plain_value?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&plain_value?/1)
  defp plain_value?(v) when is_list(v), do: Enum.all?(v, &plain_value?/1)
  defp plain_value?(_), do: false

  test "tiny clients never raise and validate" do
    for {c, r} <- [{5, 2}, {1, 1}, {3, 1}], app <- [fresh(80, 24), many(fresh(80, 24), 6)] do
      s = View.compute(app, client(c, r))
      assert :ok = Scene.validate(s), "#{c}x#{r}"
      assert status(s).rect == %{x: 0, y: r - 1, w: c, h: 1}
    end
  end
end
