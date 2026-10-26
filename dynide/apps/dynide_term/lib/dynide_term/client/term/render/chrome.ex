defmodule DynideTerm.Client.Term.Render.Chrome do
  @moduledoc """
  Chrome rasterizer (pure): the scene's chrome tree becomes two layers of row segments
  and a hit list, computed once per chrome change and reused by every frame.

    * `base`: regions disjoint from the panes (status, tabs, sidebar), assembled with
      the pane pieces.
    * `top`: modal, menu and toast regions, spliced over the assembled rows in tree
      order (later wins).
    * `hits`: `%{rect, path, role, drag}`, topmost first (top layer, later nodes first,
      then each popup pane's outer box as a `:pane` hit (`[{:pane, id}]`, topmost first:
      `Hit` passes events over it through, so the base hits under a popup never fire),
      then base; within a region its children before the region itself). Pane dividers
      are hits with `drag: true` and draw no cells (pane borders draw them).
    * `dim`: the top-of-stack `:modal` has `props.dim`.

  `layout/4` takes the scene's panes (only `layer: :popup` ones matter, as `popups/1`).

  Segments and hits are clipped to `size`. One module per region role (`:modal` and
  `:menu` share `Chrome.Modal`, which adds a whole-screen backdrop hit; `:toast` is
  `Chrome.Toast`); a region role without its own module draws a blank box of its rect
  with one hit. The root's `indicators` prop (`:dots`, default, or
  `:symbols`) picks the sidebar's badge glyphs.
  """

  alias DynideScene.Cell
  alias DynideScene.Scene
  alias DynideScene.Scene.Node
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Chrome.{Modal, Sidebar, Status, Tabs, Toast}
  alias DynideTerm.Client.Term.Theme

  @type seg :: {non_neg_integer, non_neg_integer, Cell.row()}
  @type hit :: %{
          required(:rect) => Scene.rect(),
          required(:path) => [term],
          required(:role) => atom,
          required(:drag) => boolean,
          optional(:layer) => :base | :top
        }
  @type t :: %{
          base: %{non_neg_integer => [seg]},
          top: %{non_neg_integer => [seg]},
          hits: [hit],
          dim: boolean
        }

  @top [:modal, :menu, :toast]

  @spec empty() :: t
  def empty, do: %{base: %{}, top: %{}, hits: [], dim: false}

  @doc "The `layer: :popup` panes' outer boxes (`%{id, rect}`), scene order."
  @spec popups([DynideScene.Scene.Pane.t()]) :: [%{id: pos_integer, rect: Scene.rect()}]
  def popups(panes) do
    for %{layer: :popup} = p <- panes,
        do: %{id: p.id, rect: if(p.border, do: p.border.rect, else: p.rect)}
  end

  @spec layout(
          Node.t() | nil,
          %{cols: non_neg_integer, rows: non_neg_integer},
          Theme.t(),
          [map]
        ) :: t
  def layout(chrome, size, theme, panes \\ [])
  def layout(nil, _size, _theme, _panes), do: empty()

  def layout(%Node{children: children, props: props}, size, theme, panes) do
    ind = Map.get(props, :indicators, :dots)

    {base, top} =
      children
      |> Enum.filter(&match?(%Node{rect: %{}}, &1))
      |> Enum.split_with(&(&1.role not in @top))

    {base_rows, base_hits} = layer(base, theme, ind, size)
    {top_rows, top_hits} = layer(top, theme, ind, size)
    base_hits = Enum.map(base_hits, &tag(&1, :base))
    top_hits = Enum.map(top_hits, &tag(&1, :top))

    popup_hits =
      for %{id: id, rect: r} <- Enum.reverse(popups(panes)), do: hit(r, [{:pane, id}], :pane)

    %{
      base: base_rows,
      top: top_rows,
      hits: Enum.concat(Enum.reverse(top_hits) ++ [clip_hits(popup_hits, size)] ++ base_hits),
      dim: dim?(top)
    }
  end

  @hoverable [:item, :tab]

  @doc """
  The layout with the hit at `path` drawn `:selected` (the pointer hover); `nil`, an
  unknown path or a non-item hit (`:item`, `:tab` roles only) returns it unchanged.
  Pure post-pass over the cached layout: the segments under the hit's rect get the
  `:selected` background, in the layer that owns the hit only.
  """
  @spec hover(t, [term] | nil, Theme.t()) :: t
  def hover(chrome, nil, _theme), do: chrome

  def hover(%{hits: hits} = chrome, path, theme) do
    case Enum.find(hits, &(&1.path == path)) do
      %{role: role, rect: r} = hit when role in @hoverable ->
        bg = Theme.style(theme, :selected).bg
        # only the layer that owns the hit: a base hit under an overlay must not tint it
        layer = Map.get(hit, :layer, :base)
        Map.update!(chrome, layer, &tint(&1, r, bg))

      _ ->
        chrome
    end
  end

  defp tint(layer, r, bg) do
    Enum.reduce(r.y..(r.y + r.h - 1)//1, layer, fn y, acc ->
      case acc do
        %{^y => segs} -> %{acc | y => Enum.map(segs, &tint_seg(&1, r, bg))}
        _ -> acc
      end
    end)
  end

  defp tint_seg({sx, sw, row} = seg, r, bg) do
    x0 = max(sx, r.x)
    x1 = min(sx + sw, r.x + r.w)
    if x1 > x0, do: {sx, sw, Cells.restyle(row, x0 - sx, x1 - x0, bg: bg)}, else: seg
  end

  defp tag(hits, layer), do: Enum.map(hits, &Map.put(&1, :layer, layer))

  @doc "A hit for `rect` at `path`; `drag: true` makes a press start a grab."
  @spec hit(Scene.rect(), [term], atom, boolean) :: hit
  def hit(rect, path, role, drag \\ false), do: %{rect: rect, path: path, role: role, drag: drag}

  # rows grouped by y (tree order kept), one hit list per node in tree order
  defp layer(nodes, theme, ind, size) do
    {rows, hits} = nodes |> Enum.map(&region(&1, theme, ind, size)) |> Enum.unzip()

    rows =
      rows
      |> Enum.concat()
      |> Enum.flat_map(&clip_seg(&1, size))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {rows, Enum.map(hits, &clip_hits(&1, size))}
  end

  defp region(%Node{role: :status} = n, theme, _, _), do: Status.render(n, theme)
  defp region(%Node{role: :tabs} = n, theme, _, _), do: Tabs.render(n, theme)
  defp region(%Node{role: :sidebar} = n, theme, ind, _), do: Sidebar.render(n, theme, ind)

  defp region(%Node{role: role} = n, theme, _, size) when role in [:modal, :menu],
    do: Modal.render(n, theme, size)

  defp region(%Node{role: :toast} = n, theme, _, _), do: Toast.render(n, theme)

  defp region(%Node{role: :divider, id: id, rect: r}, _, _, _),
    do: {[], [hit(r, [id], :divider, true)]}

  defp region(%Node{id: id, role: role, rect: r}, theme, _, _) do
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
