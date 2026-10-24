defmodule HerdrTerm.Client.Term.Render.Chrome do
  @moduledoc """
  Chrome rasterizer (pure): the scene's chrome tree becomes two layers of row segments
  and a hit list, computed once per chrome change and reused by every frame.

    * `base`: regions disjoint from the panes (status, tabs, sidebar), assembled with
      the pane pieces.
    * `top`: modal, menu and toast regions, spliced over the assembled rows in tree
      order (later wins).
    * `hits`: `%{rect, path, role, drag}`, topmost first (top layer, later nodes first,
      then base; within a region its children before the region itself). Pane dividers
      are hits with `drag: true` and draw no cells (pane borders draw them).
    * `dim`: the top-of-stack `:modal` has `props.dim`.

  Segments and hits are clipped to `size`. One module per region role; a region role
  without its own module (modal, menu, toast, sidebar until their tasks land) draws a
  blank box of its rect with one hit.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome.{Status, Tabs}
  alias HerdrTerm.Client.Term.Theme

  @type seg :: {non_neg_integer, non_neg_integer, Cell.row()}
  @type hit :: %{rect: Scene.rect(), path: [term], role: atom, drag: boolean}
  @type t :: %{
          base: %{non_neg_integer => [seg]},
          top: %{non_neg_integer => [seg]},
          hits: [hit],
          dim: boolean
        }

  @top [:modal, :menu, :toast]

  @spec empty() :: t
  def empty, do: %{base: %{}, top: %{}, hits: [], dim: false}

  @spec layout(Node.t() | nil, %{cols: non_neg_integer, rows: non_neg_integer}, Theme.t()) :: t
  def layout(nil, _size, _theme), do: empty()

  def layout(%Node{children: children}, size, theme) do
    {base, top} =
      children
      |> Enum.filter(&match?(%Node{rect: %{}}, &1))
      |> Enum.split_with(&(&1.role not in @top))

    {base_rows, base_hits} = layer(base, theme, size)
    {top_rows, top_hits} = layer(top, theme, size)

    %{
      base: base_rows,
      top: top_rows,
      hits: Enum.concat(Enum.reverse(top_hits) ++ base_hits),
      dim: dim?(top)
    }
  end

  @doc "A hit for `rect` at `path`; `drag: true` makes a press start a grab."
  @spec hit(Scene.rect(), [term], atom, boolean) :: hit
  def hit(rect, path, role, drag \\ false), do: %{rect: rect, path: path, role: role, drag: drag}

  # rows grouped by y (tree order kept), one hit list per node in tree order
  defp layer(nodes, theme, size) do
    {rows, hits} = nodes |> Enum.map(&region(&1, theme)) |> Enum.unzip()

    rows =
      rows
      |> Enum.concat()
      |> Enum.flat_map(&clip_seg(&1, size))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {rows, Enum.map(hits, &clip_hits(&1, size))}
  end

  defp region(%Node{role: :status} = n, theme), do: Status.render(n, theme)
  defp region(%Node{role: :tabs} = n, theme), do: Tabs.render(n, theme)
  defp region(%Node{role: :divider, id: id, rect: r}, _), do: {[], [hit(r, [id], :divider, true)]}

  defp region(%Node{id: id, role: role, rect: r}, theme) do
    blank = Cells.blank(r.w, Theme.style(theme, :default))
    {for(y <- r.y..(r.y + r.h - 1)//1, do: {y, {r.x, r.w, blank}}), [hit(r, [id], role)]}
  end

  defp clip_seg({y, {x, w, row}}, %{cols: cols, rows: rows}) do
    cond do
      y >= rows or x >= cols or w == 0 -> []
      x + w > cols -> [{y, {x, cols - x, Cells.fit(row, 0, cols - x)}}]
      true -> [{y, {x, w, row}}]
    end
  end

  defp clip_hits(hits, %{cols: cols, rows: rows}) do
    for %{rect: r} = h <- hits, r.x < cols, r.y < rows, r.w > 0, r.h > 0 do
      %{h | rect: %{r | w: min(r.w, cols - r.x), h: min(r.h, rows - r.y)}}
    end
  end

  defp dim?(top) do
    case top |> Enum.filter(&(&1.role == :modal)) |> List.last() do
      %Node{props: props} -> Map.get(props, :dim) == true
      nil -> false
    end
  end
end
