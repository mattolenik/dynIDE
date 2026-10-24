defmodule HerdrTerm.Client.Term.Render.Chrome.SidebarTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Fixture}
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome
  alias HerdrTerm.Client.Term.Theme

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
    assert Enum.at(rows, split + 2) |> String.starts_with?(" · 1")
    assert Enum.at(rows, split + 3) |> String.starts_with?("   terminal")

    for r <- rows, do: assert(String.at(r, 25) == "│")
    assert String.length(hd(rows)) == 26

    assert %{drag: false} = hit(l, [:sidebar, :spaces, :list, {:workspace, 1}])
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

  defp put_text(%Node{} = n, [], t), do: %{n | text: t}

  defp put_text(%Node{} = n, [id | rest], t) do
    %{n | children: Enum.map(n.children, &if(&1.id == id, do: put_text(&1, rest, t), else: &1))}
  end
end
