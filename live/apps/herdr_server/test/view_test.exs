defmodule HerdrServer.ViewTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Actions
  alias HerdrServer.Client.State
  alias HerdrServer.View

  defp client(c, r, transport \\ :ref, mode \\ :terminal),
    do: %State{size: %{cols: c, rows: r}, transport: transport, mode: mode}

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

  test "mode and hint follow the client's own input mode" do
    app = fresh(80, 24)
    s = View.compute(app, client(80, 24, :ref, :prefix))
    assert %{text: "PREFIX", token: :accent} = child(s, :mode)
    assert child(View.compute(app, client(80, 24)), :mode).text == "TERMINAL"
    assert mode_after(app, ["r"]) == :resize
    s = View.compute(app, client(80, 24, :ref, :resize))
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

  test "content rects lie inside their borders and the scene" do
    sizes = [{5, 2}, {1, 1}, {3, 1}, {2, 3}, {4, 4}, {7, 3}, {10, 5}]

    for n <- [2, 3, 6, 15], {c, r} <- sizes do
      s = View.compute(many(fresh(80, 24), n), client(c, r))
      assert :ok = Scene.validate(s)

      for %{rect: k, border: b} <- s.panes do
        assert k.x >= b.rect.x and k.y >= b.rect.y
        assert k.x + k.w <= b.rect.x + b.rect.w and k.y + k.h <= b.rect.y + b.rect.h
      end
    end
  end

  test "mode and hint nodes are self-describing" do
    s = View.compute(fresh(80, 24), client(80, 24))
    assert child(s, :mode).props == %{mode: :terminal}
    assert child(s, :hint).props == %{key: "b", mods: [:ctrl]}
  end

  test "tiny clients never raise and validate" do
    for {c, r} <- [{5, 2}, {1, 1}, {3, 1}], app <- [fresh(80, 24), many(fresh(80, 24), 6)] do
      s = View.compute(app, client(c, r))
      assert :ok = Scene.validate(s), "#{c}x#{r}"
      assert status(s).rect == %{x: 0, y: r - 1, w: c, h: 1}
    end
  end

  test "a notice renders after the tabs, truncated to the free width, dropped when tiny" do
    notice = %{level: :warning, text: String.duplicate("w", 200)}
    s = View.compute(fresh(80, 24), %{client(80, 24) | notice: notice})
    assert :ok = Scene.validate(s)
    assert [:mode, :tabs, :notice, :title, :hint] == Enum.map(status(s).children, & &1.id)
    n = child(s, :notice)
    assert %Node{role: :text, token: :warning} = n
    # 80 - "TERMINAL " - " 1:1 " and gap - "ctrl+b" and gap
    assert String.length(n.text) == 80 - 9 - 6 - 7

    assert child(View.compute(fresh(80, 24), client(80, 24)), :notice) == nil
    tiny = View.compute(fresh(24, 10), %{client(24, 10) | notice: notice})
    assert child(tiny, :notice) == nil
    info = View.compute(fresh(80, 24), %{client(80, 24) | notice: %{notice | level: :info}})
    assert child(info, :notice).token == :muted
  end
end
