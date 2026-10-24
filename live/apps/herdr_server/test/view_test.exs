defmodule HerdrServer.ViewTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Actions
  alias HerdrServer.App.Modal.Prompt
  alias HerdrServer.Client.State
  alias HerdrServer.RuntimeStatus
  alias HerdrServer.View
  alias HerdrServer.View.Status

  defp client(c, r, transport \\ :ref, mode \\ :terminal),
    do: %State{size: %{cols: c, rows: r}, transport: transport, mode: mode}

  defp status(scene), do: Node.find(scene.chrome, [:status])
  defp child(scene, id), do: Node.find(scene.chrome, [:status, id])
  defp tabs_node(scene), do: Node.find(scene.chrome, [:tabs])
  defp dividers(scene), do: Enum.filter(scene.chrome.children, &(&1.role == :divider))

  test "single pane" do
    s = View.compute(fresh(80, 24), client(80, 24))
    assert :ok = Scene.validate(s)

    assert [%{id: 1, rect: %{x: 26, y: 1, w: 54, h: 22}, border: nil, rows: {:ref, 1, 0}}] =
             s.panes

    assert status(s).rect == %{x: 0, y: 23, w: 80, h: 1}
    assert tabs_node(s).rect == %{x: 26, y: 0, w: 54, h: 1}
    assert [:mode | _] = Enum.map(status(s).children, & &1.id)
    refute Enum.any?(status(s).children, &(&1.role == :tabs))
    assert s.focus == %{pane: 1, chrome: nil}
    assert child(s, :hint).text == "ctrl+b"
  end

  test "two panes side by side" do
    s = View.compute(pfx(fresh(120, 40), "v"), client(120, 40))
    assert :ok = Scene.validate(s)

    assert [%{rect: %{x: 27, y: 2, w: 45, h: 36}}, %{rect: %{x: 74, y: 2, w: 45, h: 36}}] =
             s.panes

    assert [%{border: %{rect: %{x: 26, w: 47}}}, _] = s.panes
    assert [%Node{id: {:divider, []}, rect: %{x: 73, y: 1, w: 1, h: 38}}] = dividers(s)
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

  test "prefix and resize modes show mode-bar hints after the mode" do
    app = fresh(80, 24)

    hints = fn mode ->
      View.compute(app, client(80, 24, :ref, mode))
      |> status()
      |> Map.get(:children)
      |> Enum.filter(&match?({_, _}, &1.id))
      |> Enum.map(&{&1.role, &1.text})
    end

    assert hints.(:prefix) == [
             {:keycap, "esc"},
             {:text, "cancel"},
             {:keycap, "ctrl+b"},
             {:text, "send prefix"},
             {:keycap, "?"},
             {:text, "keybinds"}
           ]

    assert [{:keycap, "h"}, {:keycap, "l"}, {:text, "width"} | _] = hints.(:resize)
    assert hints.(:terminal) == []

    s = View.compute(app, client(80, 24, :ref, :prefix))

    assert [%{id: :mode}, %{role: :keycap, props: %{key: :escape, mods: []}} | _] =
             status(s).children

    assert %{props: %{key: "b", mods: [:ctrl]}} = child(s, {:key, 1})
    assert %{token: :muted} = child(s, {:hint_text, 0})
    assert child(s, :hint).text == "ctrl+b"
  end

  test "tabs mark the active one" do
    s = View.compute(new_tab(fresh(80, 24)), client(80, 24))

    assert [
             %{role: :tab, props: %{index: 1, active: false, zoomed: false}},
             %{role: :tab, props: %{index: 2, active: true}},
             %{role: :button, id: :new_tab, props: %{action: :new_tab}}
           ] = tabs_node(s).children

    assert s.focus.pane == 2
  end

  test "pane title feeds the title node and border" do
    {app, _} = Actions.apply(pfx(fresh(80, 24), "v"), {:pane_title, 2, "vim"})
    s = View.compute(app, client(80, 24))
    assert child(s, :title).text == "vim"
    assert Enum.at(s.panes, 1).border.title == "vim"
  end

  test "renamed pane shows as border title unless the program set one" do
    {app, _} = Actions.rename_pane(pfx(fresh(80, 24), "v"), 2, "build")
    assert Enum.at(View.compute(app, client(80, 24)).panes, 1).border.title == "build"
    {app, _} = Actions.apply(app, {:pane_title, 2, "vim"})
    assert Enum.at(View.compute(app, client(80, 24)).panes, 1).border.title == "vim"
    legacy = update_in(app.session.panes[2], &Map.delete(&1, :name))
    assert Enum.at(View.compute(legacy, client(80, 24)).panes, 1).border.title == "vim"
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
  # the root's theme names (resolved by each client)
  defp plain_value?(v) when is_map(v), do: plain?(v)
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
    apps = [fresh(80, 24), many(fresh(80, 24), 6), new_tab(pfx(fresh(80, 24), "b"))]

    for c <- Enum.to_list(1..30) ++ [46, 50], r <- 1..8, app <- apps do
      s = View.compute(app, client(c, r))
      assert :ok = Scene.validate(s), "#{c}x#{r}"
      assert status(s).rect == %{x: 0, y: r - 1, w: c, h: 1}
    end
  end

  test "pane rects and dividers never overlap the sidebar or the tab bar" do
    for app <- [many(fresh(120, 40), 15), pfx(many(fresh(120, 40), 4), "b")] do
      s = View.compute(app, client(120, 40))
      assert :ok = Scene.validate(s)
      %{x: tx, y: 0, h: 1} = tabs_node(s).rect
      assert tx in [4, 26]
      rects = Enum.map(s.panes, &((&1.border && &1.border.rect) || &1.rect))

      for r <- rects ++ Enum.map(dividers(s), & &1.rect) do
        assert r.x >= tx and r.y >= 1 and r.y + r.h <= 39
      end
    end
  end

  test "a notice renders after the mode, truncated to the free width, dropped when tiny" do
    notice = %{level: :warning, text: String.duplicate("w", 200)}
    s = View.compute(fresh(80, 24), %{client(80, 24) | notice: notice})
    assert :ok = Scene.validate(s)
    assert [:mode, :notice, :title, :hint] == Enum.map(status(s).children, & &1.id)
    n = child(s, :notice)
    assert %Node{role: :text, token: :warning} = n
    # 80 - "TERMINAL " - "ctrl+b" and gap
    assert String.length(n.text) == 80 - 9 - 7

    assert child(View.compute(fresh(80, 24), client(80, 24)), :notice) == nil
    tiny = View.compute(fresh(19, 10), %{client(19, 10) | notice: notice})
    assert child(tiny, :notice) == nil
    info = View.compute(fresh(80, 24), %{client(80, 24) | notice: %{notice | level: :info}})
    assert child(info, :notice).token == :muted
  end

  defp tabs(app, n), do: Enum.reduce(2..n//1, app, fn _, a -> new_tab(a) end)

  test "runtime status sits after the mode, before the notice, and the hint stays at 50 cols" do
    rt =
      Enum.reduce(
        [
          {:herdr_reload, {:loaded, 3, [A, B]}},
          {:herdr_reload, {:tests, :failed, %{files: 2, failures: 1, ms: 40}}},
          {:handoff, %{phase: :adopted, gen: 2, panes: [1], kind: :graceful}}
        ],
        RuntimeStatus.new(),
        &RuntimeStatus.apply(&2, &1, 0)
      )

    notice = %{level: :warning, text: String.duplicate("w", 200)}
    c = %{client(50, 24) | notice: notice, runtime: rt}
    s = View.compute(tabs(fresh(80, 24), 6), c)
    assert :ok = Scene.validate(s)
    ids = Enum.map(status(s).children, & &1.id)
    # 50 - 9 - 7 = 34: reload (6) and tests (15) fit, handoff (20) not; tabs take no room
    assert ids == [:mode, :reload, :tests, :notice, :title, :hint]
    assert %Node{text: "r3 2m", props: %{batch: 3, fanout: 2}} = child(s, :reload)
    assert child(s, :hint).text == "ctrl+b"
    assert String.length(child(s, :notice).text) == 34 - 6 - 15
    # width/1 counts a gap after the last node (the hint) that is never drawn
    assert Status.width(status(s).children) - 1 <= 50

    # a wide client shows all three
    s = View.compute(tabs(fresh(200, 24), 6), %{client(200, 24) | runtime: rt})

    assert [:mode, :reload, :tests, :handoff, :title, :hint] ==
             Enum.map(status(s).children, & &1.id)

    # no runtime, no nodes
    s = View.compute(fresh(80, 24), client(80, 24))
    assert [:mode, :title, :hint] == Enum.map(status(s).children, & &1.id)
  end

  test "an open prompt is the last chrome child; the scene cursor sits in its input" do
    {app, []} = Prompt.rename_tab(fresh(80, 24))
    s = View.compute(app, client(80, 24))
    assert :ok = Scene.validate(s)
    assert %Node{role: :modal, id: {:modal, 1}} = List.last(s.chrome.children)
    assert s.focus == %{pane: 1, chrome: [{:modal, 1}, :input]}
    # panel x 12, y 8; input row y + 3, text from x + 2, cursor after "1"
    assert s.cursor == %{x: 15, y: 11, shape: :bar}

    # long text scrolls: the cursor stays inside the input row
    app =
      update_in(app.focus.modal, fn [m | r] ->
        [%{m | field: %{text: String.duplicate("y", 64), cursor: 64}} | r]
      end)

    s = View.compute(app, client(80, 24))
    assert :ok = Scene.validate(s)
    assert Node.find(s.chrome, [{:modal, 1}, :input]).props.offset == 64 - 52
    assert s.cursor.x == 12 + 2 + 52

    # no modal: no chrome focus, no scene cursor
    s = View.compute(fresh(80, 24), client(80, 24))
    assert s.focus.chrome == nil and s.cursor == nil
  end

  test "an open prompt validates at every size, tiny ones included" do
    {app, []} = Prompt.rename_tab(fresh(80, 24))

    for c <- [1, 10, 20, 80], r <- [1, 3, 5, 24] do
      s = View.compute(app, client(c, r))
      assert :ok = Scene.validate(s), "#{c}x#{r}"
    end
  end

  test "copy mode shows COPY, or the open search prompt" do
    app = fresh(80, 24)
    s = View.compute(app, client(80, 24, :ref, :copy))
    assert %{text: "COPY", token: :accent} = child(s, :mode)

    copy = %HerdrServer.Client.CopyMode{pane: 1, prompt: %{dir: :backward, query: "ab"}}
    s = View.compute(app, %{client(80, 24, :ref, :copy) | copy: copy})
    assert %{text: "?ab", token: :accent} = child(s, :mode)
  end
end
