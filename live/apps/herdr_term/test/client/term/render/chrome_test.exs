defmodule HerdrTerm.Client.Term.Render.ChromeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Chrome, Fixture}
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome, as: RChrome
  alias HerdrTerm.Client.Term.Render.Chrome.Text
  alias HerdrTerm.Client.Term.Theme

  @theme Theme.default()
  @size %{cols: 80, rows: 24}

  defp text(id, t, token \\ :default), do: %Node{role: :text, id: id, text: t, token: token}

  defp status(children \\ [text(:mode, "TERMINAL"), text(:hint, "ctrl+b", :muted)]),
    do: %Node{role: :status, id: :status, rect: %{x: 0, y: 23, w: 80, h: 1}, children: children}

  defp tabs(names, active, rect \\ %{x: 0, y: 0, w: 80, h: 1}) do
    ts =
      names
      |> Enum.with_index(1)
      |> Enum.map(fn {n, i} ->
        %Node{role: :tab, id: {:tab, i}, text: n, props: %{index: i, active: i == active}}
      end)

    new = %Node{role: :button, id: :new_tab, props: %{action: :new_tab}}
    %Node{role: :tabs, id: :tabs, rect: rect, children: ts ++ [new]}
  end

  defp root(children), do: %Node{role: :root, id: :root, children: children}

  defp hit(layout, path), do: Enum.find(layout.hits, &(&1.path == path))

  test "nil chrome is empty" do
    assert RChrome.layout(nil, @size, @theme) == %{base: %{}, top: %{}, hits: [], dim: false}
  end

  test "a status-only chrome gives base on the last row only and no top" do
    layout = RChrome.layout(root([status()]), @size, @theme)
    assert Map.keys(layout.base) == [23]
    assert layout.top == %{}
    refute layout.dim
    [{0, 80, row}] = layout.base[23]
    assert Cells.to_text(row) == "TERMINAL" <> String.duplicate(" ", 66) <> "ctrl+b"
  end

  test "tabs render centred labels, a gap, the new-tab button and hits" do
    layout = RChrome.layout(root([tabs(["1", "2"], 2), status()]), @size, @theme)
    [{0, 80, row}] = layout.base[0]
    expected = "   1    " <> " " <> "   2    " <> " + "
    assert String.slice(Cells.to_text(row), 0, String.length(expected)) == expected
    assert Cell.cols(row) == 80

    cells = Cell.decode_row(row)
    assert Enum.at(cells, 12).bg == Theme.style(@theme, :selected).bg
    assert Enum.at(cells, 3).bg == Theme.style(@theme, :surface).bg

    assert %{rect: %{x: 0, y: 0, w: 8, h: 1}, role: :tab, drag: false} =
             hit(layout, [:tabs, {:tab, 1}])

    assert %{rect: %{x: 9, y: 0, w: 8, h: 1}} = hit(layout, [:tabs, {:tab, 2}])
    assert %{rect: %{x: 17, y: 0, w: 3, h: 1}, role: :button} = hit(layout, [:tabs, :new_tab])
    assert %{rect: %{x: 0, y: 0, w: 80, h: 1}, role: :tabs} = hit(layout, [:tabs])
    # children before their region: topmost first
    assert Enum.find_index(layout.hits, &(&1.path == [:tabs, {:tab, 2}])) <
             Enum.find_index(layout.hits, &(&1.path == [:tabs]))
  end

  test "a zoomed tab's label gets a Z in front" do
    t = tabs(["1", "2"], 2)
    [one, two | rest] = t.children
    t = %{t | children: [one, %{two | props: Map.put(two.props, :zoomed, true)} | rest]}
    layout = RChrome.layout(root([t]), @size, @theme)
    [{0, 80, row}] = layout.base[0]
    assert String.starts_with?(Cells.to_text(row), "   1    " <> " " <> "  Z 2   " <> " + ")
  end

  test "tabs start at the region's x and long labels widen the tab" do
    layout =
      RChrome.layout(root([tabs(["shell", "x"], 1, %{x: 26, y: 0, w: 54, h: 1})]), @size, @theme)

    [{26, 54, row}] = layout.base[0]
    assert String.starts_with?(Cells.to_text(row), "  shell  " <> " " <> "   x    " <> " + ")
    assert %{rect: %{x: 26, w: 9}} = hit(layout, [:tabs, {:tab, 1}])
    assert %{rect: %{x: 36, w: 8}} = hit(layout, [:tabs, {:tab, 2}])
  end

  test "tabs that do not fit are cut and the last visible cell is an ellipsis" do
    layout =
      RChrome.layout(
        root([tabs(["aaaa", "bbbb", "cccc"], 1, %{x: 0, y: 0, w: 20, h: 1})]),
        @size,
        @theme
      )

    [{0, 20, row}] = layout.base[0]
    assert Cells.to_text(row) == "  aaaa  " <> " " <> "  bbbb  " <> " " <> " …"
    assert %{rect: %{x: 9, w: 8}} = hit(layout, [:tabs, {:tab, 2}])
    assert %{rect: %{x: 18, w: 2}} = hit(layout, [:tabs, {:tab, 3}])
    assert hit(layout, [:tabs, :new_tab]) == nil
  end

  test "dividers produce drag hits and no cells" do
    div = %Node{
      role: :divider,
      id: {:divider, []},
      rect: %{x: 40, y: 1, w: 1, h: 22},
      props: %{direction: :horizontal, path: []}
    }

    layout = RChrome.layout(root([div, status()]), @size, @theme)
    assert Map.keys(layout.base) == [23]

    assert hit(layout, [{:divider, []}]) == %{
             rect: %{x: 40, y: 1, w: 1, h: 22},
             path: [{:divider, []}],
             role: :divider,
             drag: true,
             layer: :base
           }
  end

  test "status keycap hints use the accent token, their text muted" do
    hints = [
      text(:mode, "PREFIX", :accent),
      %Node{role: :keycap, id: {:key, 0}, text: "esc", props: %{key: :escape, mods: []}},
      text({:hint_text, 0}, "cancel", :muted),
      %Node{role: :keycap, id: {:key, 1}, props: %{key: "w", mods: [:ctrl]}},
      text({:hint_text, 1}, "nav", :muted)
    ]

    [{0, 80, row}] = RChrome.layout(root([status(hints)]), @size, @theme).base[23]
    assert String.starts_with?(Cells.to_text(row), "PREFIX esc cancel ctrl+w nav")
    cells = Cell.decode_row(row)
    assert Enum.at(cells, 7).fg == Theme.style(@theme, :accent).fg
    assert Enum.at(cells, 11).attrs == Theme.style(@theme, :muted).attrs
  end

  test "status ignores tabs nested inside it" do
    nested = status([text(:mode, "TERMINAL"), tabs(["x"], 1, nil)])
    [{0, 80, row}] = RChrome.layout(root([nested]), @size, @theme).base[23]
    assert Cells.to_text(row) == "TERMINAL" <> String.duplicate(" ", 72)
  end

  test "a modal is a box in the top layer with its hit, dim from its props" do
    modal = %Node{
      role: :modal,
      id: {:modal, 0},
      rect: %{x: 10, y: 5, w: 20, h: 3},
      props: %{kind: :confirm, dim: true}
    }

    layout = RChrome.layout(root([status(), modal]), @size, @theme)
    assert layout.dim
    assert Map.keys(layout.top) == [5, 6, 7]
    assert [{10, 20, row}] = layout.top[6]
    assert Cell.cols(row) == 20

    assert hd(layout.hits) == %{
             rect: modal.rect,
             path: [{:modal, 0}],
             role: :modal,
             drag: false,
             layer: :top
           }

    refute RChrome.layout(root([%{modal | props: %{kind: :confirm}}]), @size, @theme).dim
  end

  test "regions are clipped to the screen" do
    toast = %Node{
      role: :toast,
      id: {:toast, 1},
      rect: %{x: 70, y: 22, w: 20, h: 4},
      props: %{level: :info}
    }

    layout = RChrome.layout(root([toast]), @size, @theme)
    assert Map.keys(layout.top) == [22, 23]
    assert [{70, 10, row}] = layout.top[22]
    assert Cell.cols(row) == 10
  end

  test "every golden fixture's layout covers exactly its region rects" do
    for name <- Fixture.names() do
      sc = Fixture.load(name)
      layout = RChrome.layout(sc.chrome, sc.size, @theme)

      covered =
        for {y, segs} <- Map.merge(layout.base, layout.top, fn _, a, b -> a ++ b end),
            {x, w, row} <- segs,
            tap(Cell.cols(row) == w, &assert(&1, name)),
            cx <- x..(x + w - 1)//1,
            into: MapSet.new(),
            do: {cx, y}

      regions =
        for %Node{role: role, rect: %{} = r} <- sc.chrome.children,
            role in Chrome.region_roles() and role != :divider,
            x <- r.x..(r.x + r.w - 1)//1,
            y <- r.y..(r.y + r.h - 1)//1,
            into: MapSet.new(),
            do: {x, y}

      assert covered == regions, name
    end
  end

  test "text helpers: clip pads or cuts, pill pads, join separates" do
    s = Theme.style(@theme, :default)
    assert Cells.to_text(Text.clip(Cells.text("abc", s), 5, s)) == "abc  "
    assert Cells.to_text(Text.clip(Cells.text("abcdef", s), 4, s)) == "abcd"
    assert Cells.to_text(Text.pill("PREFIX", :accent, @theme)) == " PREFIX "

    assert Cells.to_text(
             Text.join([Cells.text("a", s), Cells.text("b", s)], Cells.text(" · ", s))
           ) ==
             "a · b"

    assert Cells.to_text(Text.ellipsize(Cells.text("abcdef", s), 4, @theme)) == "abc…"
  end

  describe "hover" do
    test "an inactive tab under the pointer takes the :selected background; nil restores" do
      layout = RChrome.layout(root([tabs(["a", "b"], 1)]), @size, @theme)
      path = [:tabs, {:tab, 2}]
      assert RChrome.hover(layout, nil, @theme) == layout
      assert RChrome.hover(layout, [:nope], @theme) == layout

      hovered = RChrome.hover(layout, path, @theme)
      %{rect: r} = hit(layout, path)
      bg = Theme.style(@theme, :selected).bg

      cell = fn l, x ->
        l.base
        |> Map.fetch!(0)
        |> Enum.find(fn {sx, w, _} -> x >= sx and x < sx + w end)
        |> then(fn {sx, _, row} -> row |> Cell.decode_row() |> Enum.at(x - sx) end)
      end

      refute cell.(layout, r.x).bg == bg
      assert cell.(hovered, r.x).bg == bg
      assert cell.(hovered, r.x + r.w - 1).bg == bg
      assert cell.(hovered, r.x + r.w).bg == cell.(layout, r.x + r.w).bg
    end

    test "a wide-glyph tab is tinted across its whole rect, no further" do
      layout = RChrome.layout(root([tabs(["日本語", "b"], 1)]), @size, @theme)
      path = [:tabs, {:tab, 1}]
      %{rect: r} = hit(layout, path)
      bg = Theme.style(@theme, :selected).bg

      cells = fn l ->
        l.base |> Map.fetch!(0) |> Enum.flat_map(fn {_, _, row} -> Cell.decode_row(row) end)
      end

      before = cells.(layout)
      hov = cells.(RChrome.hover(layout, [:tabs, {:tab, 2}], @theme))
      assert Enum.slice(hov, 0, r.x + r.w) == Enum.slice(before, 0, r.x + r.w)
      assert Enum.all?(Enum.slice(hov, hit(layout, [:tabs, {:tab, 2}]).rect.x, 8), &(&1.bg == bg))
    end

    test "a tab hovered under an open menu leaves the menu cells unchanged" do
      menu = %Node{
        role: :menu,
        id: :menu,
        rect: %{x: 0, y: 0, w: 30, h: 4},
        children: [%Node{role: :item, id: :one, text: "one"}]
      }

      layout = RChrome.layout(root([tabs(["a", "b"], 1), menu]), @size, @theme)
      path = [:tabs, {:tab, 2}]
      assert hit(layout, path).layer == :base
      hov = RChrome.hover(layout, path, @theme)
      assert hov.top == layout.top
      refute hov.base == layout.base
    end

    test "non-item hits (the status bar, a button) do not hover" do
      layout = RChrome.layout(root([status(), tabs(["a"], 1)]), @size, @theme)
      assert RChrome.hover(layout, [:status], @theme) == layout
      assert RChrome.hover(layout, [:tabs, :new_tab], @theme) == layout
    end
  end
end
