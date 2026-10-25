defmodule HerdrTerm.Client.Term.Render.Chrome.Tabs do
  @moduledoc """
  The tab bar region (pure, inventory §3): each `:tab` is its label (`Z ` in front while
  `zoomed`; plain ASCII, so no width ambiguity) centred in
  `max(label + 4, 8)` cells, `:selected` when active and `:surface` otherwise, one blank
  between tabs; the `:new_tab` button is `" + "` right after the last tab. A bar that
  does not fit is cut and its last visible cell becomes `…`. Hits: every (visible part
  of a) tab and button, then the region itself.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome
  alias HerdrTerm.Client.Term.Render.Chrome.Text
  alias HerdrTerm.Client.Term.Theme

  @spec render(Node.t(), Theme.t()) :: {[{non_neg_integer, Chrome.seg()}], [Chrome.hit()]}
  def render(%Node{id: id, rect: r, children: children} = node, theme) do
    bar = Theme.style(theme, :default)
    gap = Text.text(" ", :default, theme)

    placed = children |> Enum.flat_map(&piece(&1, theme)) |> place()

    row =
      placed |> Enum.flat_map(fn {_, _, p, g} -> List.duplicate(gap, g) ++ [p] end) |> concat()

    first =
      if Cell.cols(row) > r.w, do: Text.ellipsize(row, r.w, theme), else: Text.clip(row, r.w, bar)

    rows =
      for y <- r.y..(r.y + r.h - 1)//1,
          do: {y, {r.x, r.w, if(y == r.y, do: first, else: Cells.blank(r.w, bar))}}

    hits =
      for {child, x, p, _} <- placed, (w = min(x + Cell.cols(p), r.w) - x) > 0 do
        Chrome.hit(%{x: r.x + x, y: r.y, w: w, h: 1}, [id, child.id], child.role)
      end

    {rows, hits ++ [Chrome.hit(r, [id], node.role)]}
  end

  # `{child, x, piece, gap}` with x after the gap: one blank between two tabs
  defp place(pieces) do
    {placed, _} =
      Enum.map_reduce(pieces, {0, nil}, fn {child, p}, {x, prev} ->
        g = if prev == :tab and child.role == :tab, do: 1, else: 0
        {{child, x + g, p, g}, {x + g + Cell.cols(p), child.role}}
      end)

    placed
  end

  defp piece(%Node{role: :tab, text: name, props: props} = n, theme) do
    token = if Map.get(props, :active), do: :selected, else: :surface
    label = if(Map.get(props, :zoomed), do: "Z ", else: "") <> to_string(name || "")
    label_cells = Text.text(label, token, theme)
    [{n, Text.center(label_cells, max(Cell.cols(label_cells) + 4, 8), Theme.style(theme, token))}]
  end

  defp piece(%Node{role: :button, id: :new_tab} = n, theme),
    do: [{n, Text.text(" + ", :muted, theme)}]

  defp piece(_other, _theme), do: []

  defp concat([]), do: Cell.blank_row(0)
  defp concat(pieces), do: Cell.concat(pieces)
end
