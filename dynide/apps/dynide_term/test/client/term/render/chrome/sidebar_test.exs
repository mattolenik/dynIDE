defmodule DynideTerm.Client.Term.Render.Chrome.SidebarTest do
  use ExUnit.Case, async: true

  alias DynideScene.{Cell, Fixture}
  alias DynideScene.Scene.Node
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Chrome
  alias DynideTerm.Client.Term.Theme

  @theme Theme.default()

  defp layout(scene), do: Chrome.layout(scene.chrome, scene.size, @theme)

  # the sidebar's segment of row y (x 0) as text and cells
  defp row(layout, y) do
    {0, _w, cells} = Enum.find(layout.base[y], &(elem(&1, 0) == 0))
    cells
  end

  defp text(layout, y), do: layout |> row(y) |> Cells.to_text()
  defp texts(layout, h), do: for(y <- 0..(h - 1), do: text(layout, y))
  defp hit(layout, path), do: Enum.find(layout.hits, &(&1.path == path))
  defp sidebar(scene), do: Node.find(scene.chrome, [:sidebar])

  test "expanded: spaces header, footer, rule, agents header, edge, hits" do
    scene = Fixture.load("sidebar_expanded_120x40")
    l = layout(scene)
    h = sidebar(scene).rect.h
    rows = texts(l, h)

    assert String.starts_with?(hd(rows), " spaces")
    assert Enum.at(rows, 1) |> String.trim_trailing("│") |> String.trim() == ""
    assert String.starts_with?(Enum.at(rows, 2), " · 1")
    assert Enum.any?(rows, &String.ends_with?(&1, "menu│"))
    footer = Enum.find(rows, &String.ends_with?(&1, "menu│"))
    assert String.starts_with?(footer, " new")

    split = Enum.find_index(rows, &String.starts_with?(&1, "─"))
    assert split
    assert String.starts_with?(Enum.at(rows, split + 1), " agents")
    assert String.ends_with?(Enum.at(rows, split + 1), "grouped│")
    assert %{rect: %{x: 18, y: y, w: 7}} = hit(l, [:sidebar, :agents, :sort])
    assert y == split + 1
    assert Enum.at(rows, split + 2) |> String.starts_with?(" · 1")
    assert Enum.at(rows, split + 3) |> String.starts_with?("   terminal")

    for r <- rows, do: assert(String.at(r, 25) == "│")
    assert String.length(hd(rows)) == 26

    assert %{drag: true} = hit(l, [:sidebar, :spaces, :list, {:workspace, 1}])
    assert %{rect: %{x: 0, w: 4}} = hit(l, [:sidebar, :spaces, :new])
    assert %{rect: %{x: 21, w: 4}} = hit(l, [:sidebar, :spaces, :menu])
    assert %{rect: %{x: 25, y: 0, w: 1, h: ^h}, drag: true} = hit(l, [:sidebar, :edge])
    assert %{rect: %{y: ^split, h: 1}, drag: true} = hit(l, [:sidebar, :split])
    assert hit(l, [:sidebar, :agents, :list, {:pane, 1}]).rect.h == 2
    assert %{rect: %{x: 24, y: y}} = hit(l, [:sidebar, :toggle])
    assert y == h - 1
    assert String.at(Enum.at(rows, h - 1), 24) == "«"
    assert hit(l, [:sidebar, :spaces])
    assert hit(l, [:sidebar, :agents])

    # children before their region
    paths = Enum.map(l.hits, & &1.path)

    assert Enum.find_index(paths, &(&1 == [:sidebar, :spaces, :new])) <
             Enum.find_index(paths, &(&1 == [:sidebar, :spaces]))

    assert Enum.find_index(paths, &(&1 == [:sidebar, :agents, :sort])) <
             Enum.find_index(paths, &(&1 == [:sidebar, :agents]))

    assert List.last(Enum.filter(paths, &match?([:sidebar | _], &1))) == [:sidebar]
  end

  test "header is muted and bold, the active workspace row is selected" do
    l = layout(Fixture.load("sidebar_expanded_120x40"))
    [_, s | _] = Cell.decode_row(row(l, 0))
    assert :bold in s.attrs and :faint in s.attrs
    cells = Cell.decode_row(row(l, 2))
    assert Enum.at(cells, 5).bg == Theme.style(@theme, :selected).bg
    # the badge keeps its state colour
    assert Enum.at(cells, 1).attrs == Theme.style(@theme, :muted).attrs
  end

  test "a navigate preview (selected) is highlighted instead of the active row" do
    scene = Fixture.load("two_workspaces_120x40")
    w = &[:spaces, :list, {:workspace, &1}]
    sel = Theme.style(@theme, :selected).bg

    bg = fn l, id ->
      Enum.at(Cell.decode_row(row(l, hit(l, [:sidebar | w.(id)]).rect.y)), 5).bg
    end

    l = layout(scene)
    assert {bg.(l, 1) != sel, bg.(l, 2)} == {true, sel}

    chrome = put_props(scene.chrome, [:sidebar | w.(1)], selected: true)
    chrome = put_props(chrome, [:sidebar | w.(2)], selected: false)
    l = layout(%{scene | chrome: chrome})
    assert {bg.(l, 1), bg.(l, 2) != sel} == {sel, true}
  end

  test "badges follow indicators and state colours" do
    scene = Fixture.load("two_workspaces_120x40")
    sb = sidebar(scene)

    blocked =
      update_in(sb.children, fn [spaces | rest] ->
        [
          update_in(spaces.children, fn [list | more] ->
            [
              update_in(list.children, fn [w1 | ws] ->
                [put_state(w1, :blocked) | ws]
              end)
              | more
            ]
          end)
          | rest
        ]
      end)

    root = %{scene.chrome | children: [blocked | tl(scene.chrome.children)]}
    l = Chrome.layout(root, scene.size, @theme)
    assert text(l, 2) |> String.starts_with?(" ● 1")
    assert Enum.at(Cell.decode_row(row(l, 2)), 1).fg == Theme.style(@theme, :error).fg
    assert text(l, 3) |> String.starts_with?(" · two")

    sym = %{root | props: %{root.props | indicators: :symbols}}
    assert Chrome.layout(sym, scene.size, @theme) |> text(2) |> String.starts_with?(" × 1")
  end

  test "agent rows: workspace and tab with a separator when the workspace has tabs" do
    scene = Fixture.load("two_workspaces_120x40")
    rows = texts(layout(scene), sidebar(scene).rect.h)
    i = Enum.find_index(rows, &String.starts_with?(&1, " agents"))
    assert String.starts_with?(Enum.at(rows, i + 1), " · 1 · 1")
    assert String.starts_with?(Enum.at(rows, i + 3), " · 1 · 2")
    assert String.starts_with?(Enum.at(rows, i + 5), " · two ")
  end

  test "long names are cut with an ellipsis" do
    scene = Fixture.load("sidebar_expanded_120x40")
    long = String.duplicate("x", 40)
    sb = sidebar(scene)
    ws_text = [:spaces, :list, {:workspace, 1}, {:line, 0}, :workspace]
    sb = put_text(sb, ws_text, long)
    root = %{scene.chrome | children: [sb | tl(scene.chrome.children)]}
    r = Chrome.layout(root, scene.size, @theme) |> text(2)
    assert String.length(r) == 26
    assert String.ends_with?(r, "x…│")
  end

  test "collapsed: index and badge rows, a rule, » bottom-centre" do
    scene = Fixture.load("sidebar_collapsed_80x24")
    l = layout(scene)
    h = sidebar(scene).rect.h
    rows = texts(l, h)
    assert Enum.all?(rows, &(String.length(&1) == 4 and String.at(&1, 3) == "│"))
    assert hd(rows) == " 1·│"
    assert Enum.at(rows, 1) == "───│"
    assert Enum.at(rows, 2) == "  ·│"
    assert Enum.at(rows, h - 1) == " » │"
    assert %{rect: %{x: 1, y: y, w: 1}} = hit(l, [:sidebar, :toggle])
    assert y == h - 1
    assert %{rect: %{y: 0, h: 1}} = hit(l, [:sidebar, :spaces, :list, {:workspace, 1}])
    assert %{rect: %{y: 2, h: 1}} = hit(l, [:sidebar, :agents, :list, {:pane, 1}])
    refute hit(l, [:sidebar, :spaces, :new])
  end

  test "tiny sidebars stay inside their rect" do
    scene = Fixture.load("sidebar_expanded_120x40")
    sb = sidebar(scene)

    for h <- 1..8, w <- [2, 4, 26] do
      small = %{sb | rect: %{sb.rect | h: h, w: w}}
      small = update_in(small.children, fn cs -> Enum.reject(cs, &(&1.id == :split)) end)
      l = Chrome.layout(%{scene.chrome | children: [small]}, scene.size, @theme)

      for {y, segs} <- l.base, {x, sw, cells} <- segs do
        assert y < h and x + sw <= w and Cell.cols(cells) == sw
      end

      for %{rect: r} <- l.hits, do: assert(r.x + r.w <= w and r.y + r.h <= h)
    end
  end

  defp put_state(item, state) do
    update_in(item.children, fn [line | rest] ->
      [update_in(line.children, fn [b | ts] -> [put_in(b.props.state, state) | ts] end) | rest]
    end)
  end

  test "expanded: an item's detail is a muted line under it" do
    scene = Fixture.load("sidebar_expanded_120x40")
    before = texts(layout(scene), sidebar(scene).rect.h)

    scene = %{
      scene
      | chrome:
          put_props(scene.chrome, [:sidebar, :spaces, :list, {:workspace, 1}], detail: "main ↑1")
    }

    l = layout(scene)
    rows = texts(l, sidebar(scene).rect.h)
    assert String.starts_with?(Enum.at(rows, 2), " · 1")
    assert String.starts_with?(Enum.at(rows, 3), "   main ↑1 ")
    assert Enum.at(rows, 4) == Enum.at(before, 3)
    cell = Enum.at(Cell.decode_row(row(l, 3)), 3)
    assert cell.fg == Theme.style(@theme, :muted).fg
    assert hit(l, [:sidebar, :spaces, :list, {:workspace, 1}]).rect.h == 2
  end

  test "hover tints both rows of a 2-row item, nothing around it" do
    scene = Fixture.load("sidebar_expanded_120x40")
    path = [:sidebar, :spaces, :list, {:workspace, 1}]
    scene = %{scene | chrome: put_props(scene.chrome, tl(path), detail: "main ↑1")}
    l = layout(scene)
    %{rect: r} = hit(l, path)
    hov = Chrome.hover(l, path, @theme)
    bg = Theme.style(@theme, :selected).bg
    bgs = fn l, y -> l |> row(y) |> Cell.decode_row() |> Enum.map(& &1.bg) end

    for y <- r.y..(r.y + r.h - 1),
        do: assert(Enum.all?(Enum.slice(bgs.(hov, y), 0, r.w), &(&1 == bg)))

    assert bgs.(hov, r.y - 1) == bgs.(l, r.y - 1)
    assert bgs.(hov, r.y + r.h) == bgs.(l, r.y + r.h)
  end

  defp put_props(%Node{} = n, [], kv), do: %{n | props: Map.merge(n.props, Map.new(kv))}

  defp put_props(%Node{} = n, [id | rest], kv) do
    %{n | children: Enum.map(n.children, &if(&1.id == id, do: put_props(&1, rest, kv), else: &1))}
  end

  defp put_text(%Node{} = n, [], t), do: %{n | text: t}

  defp put_text(%Node{} = n, [id | rest], t) do
    %{n | children: Enum.map(n.children, &if(&1.id == id, do: put_text(&1, rest, t), else: &1))}
  end

  test "workspace items are reorder hits; a drop_marker draws the accent ▔ above or below" do
    scene = Fixture.load("sidebar_expanded_120x40")
    accent = Theme.style(@theme, :accent).fg
    path = [:sidebar, :spaces, :list, {:workspace, 1}]

    marked = fn side ->
      chrome =
        update_in(scene.chrome, [Access.key(:children)], fn cs ->
          Enum.map(cs, &mark(&1, path, side))
        end)

      layout(%{scene | chrome: chrome})
    end

    l = marked.(:before)
    %{rect: r, drag: true} = hit(l, path)
    cell = fn l, y -> l |> row(y) |> Cell.decode_row() |> hd() end
    assert %{glyph: "▔", fg: ^accent} = cell.(l, r.y)

    l = marked.(:after)
    assert %{glyph: "▔", fg: ^accent} = cell.(l, r.y + r.h)
    refute cell.(l, r.y).glyph == "▔"
    refute hit(l, [:sidebar, :agents, :list, {:pane, 1}]).drag
  end

  defp mark(%Node{id: id} = n, [id], side),
    do: %{n | props: Map.put(n.props, :drop_marker, side)}

  defp mark(%Node{id: id, children: cs} = n, [id | rest], side),
    do: %{n | children: Enum.map(cs, &mark(&1, rest, side))}

  defp mark(n, _path, _side), do: n
end
