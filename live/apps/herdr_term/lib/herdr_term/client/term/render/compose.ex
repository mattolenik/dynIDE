defmodule HerdrTerm.Client.Term.Render.Compose do
  @moduledoc """
  Pure rasterizer: a `HerdrScene.Scene` plus packed pane rows becomes full
  screen rows of packed cells. Each screen row is built once as a list of
  pieces (borders, `Cells.fit` slices of pane rows, status text) and joined
  once (plain pieces as sub-binaries, else `Cells.concat/1`); pane content
  is never touched per cell except where an overlay applies.

  Pieces on a row are expected to be disjoint (borders win over the content
  they overlap; otherwise the leftmost piece wins).
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Pane}
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Theme

  @typedoc "Packed rows per pane id; panes absent here fall back to their `{:inline, rows}`."
  @type rows_by_pane :: %{
          pos_integer => tuple | [{non_neg_integer, binary}] | %{non_neg_integer => binary}
        }

  @doc "`{frame/3, cursor/2}`: one guarded call per frame instead of two."
  @spec screen(Scene.t(), rows_by_pane, %{pos_integer => map | nil}, Theme.t()) ::
          {[{non_neg_integer, binary}], {{non_neg_integer, non_neg_integer}, Scene.shape()} | nil}
  def screen(scene, rows_by_pane, cursors, theme),
    do: {frame(scene, rows_by_pane, theme), cursor(scene, cursors)}

  @spec frame(Scene.t(), rows_by_pane, Theme.t()) :: [{non_neg_integer, binary}]
  def frame(%Scene{size: %{cols: cols, rows: rows}} = scene, rows_by_pane, theme) do
    {panes, _cache} =
      Enum.map_reduce(scene.panes, %{}, &prep_pane(&1, &2, scene, rows_by_pane, theme))

    by_row = segs_by_row(panes, status_rows(scene.chrome, theme), rows)

    for y <- 0..(rows - 1)//1, do: {y, assemble(Map.get(by_row, y, []), cols)}
  end

  # y => segments in pane order, then status; each pane visits only the rows it spans
  defp segs_by_row(panes, status, rows) do
    pane_segs =
      for p <- panes, y <- span(p, rows), seg <- pane_segs(p, y), do: {y, seg}

    status_segs = for {y, segs} <- status, seg <- segs, do: {y, seg}
    Enum.group_by(pane_segs ++ status_segs, &elem(&1, 0), &elem(&1, 1))
  end

  defp span(%{cy: cy, ch: ch, border: b}, rows) do
    {lo, hi} = if b, do: {min(cy, b.oy), max(cy + ch, b.oy + b.oh)}, else: {cy, cy + ch}
    max(lo, 0)..(min(hi, rows) - 1)//1
  end

  @doc """
  Host cursor `{{x, y}, shape}` in screen cells, or nil: the focused pane's cursor from
  `cursors` (pane id => pane-relative cursor, as read from the row cache) placed in its
  rect, else the scene's own `cursor` (inline scenes carry it).
  """
  @spec cursor(Scene.t(), %{pos_integer => map | nil}) ::
          {{non_neg_integer, non_neg_integer}, Scene.shape()} | nil
  def cursor(%Scene{focus: %{pane: id}} = scene, cursors) do
    pane = Enum.find(scene.panes, &(&1.id == id))

    case {pane, Map.fetch(cursors, id)} do
      {%Pane{rect: r}, {:ok, c}} -> in_rect(c, r)
      _ -> scene_cursor(scene.cursor)
    end
  end

  defp in_rect(%{visible: true, x: x, y: y, shape: shape}, r) when y < r.h and r.w > 0,
    do: {{r.x + min(x, r.w - 1), r.y + y}, shape}

  defp in_rect(_hidden_or_nil, _r), do: nil

  defp scene_cursor(%{x: x, y: y, shape: shape}), do: {{x, y}, shape}
  defp scene_cursor(nil), do: nil

  # assembly

  defp assemble(segs, cols) do
    {pieces, x} =
      segs
      |> List.keysort(0)
      |> Enum.reduce({[], 0}, fn {sx, w, bin}, {acc, x} ->
        cond do
          sx >= cols or sx + w <= x -> {acc, x}
          sx >= x -> {[bin | gap(acc, sx - x)], sx + w}
          true -> {[Cells.fit(bin, x - sx, sx + w - x) | acc], sx + w}
        end
      end)

    pieces = if x < cols, do: gap(pieces, cols - x), else: pieces
    row = join(pieces)
    if Cell.cols(row) > cols, do: Cells.fit(row, 0, cols), else: row
  end

  # `Cells.concat(Enum.reverse(pieces))` with one footer read per piece: plain pieces
  # join as sub-binaries of their records, any trailer falls back to `Cells.concat/1`
  defp join(pieces), do: join(pieces, [], pieces)

  defp join([], acc, _), do: IO.iodata_to_binary([acc, <<0::32>>])

  defp join([bin | rest], acc, all) do
    case binary_part(bin, byte_size(bin), -4) do
      <<0::32>> -> join(rest, [binary_part(bin, 0, byte_size(bin) - 4) | acc], all)
      _trailer -> all |> Enum.reverse() |> Cells.concat()
    end
  end

  defp gap(acc, 0), do: acc
  defp gap(acc, n), do: [Cell.blank_row(n) | acc]

  # panes

  # `cache` holds encoded border pieces by shape: same-sized panes share them
  defp prep_pane(%Pane{rect: r} = pane, cache, scene, rows_by_pane, theme) do
    {border, cache} = prep_border(pane.border, pane.id == scene.focus.pane, cache, theme)

    prepped = %{
      cx: r.x,
      cy: r.y,
      cw: r.w,
      ch: r.h,
      src: rows_source(Map.get(rows_by_pane, pane.id, inline(pane.rows))),
      overlays: pane.overlays,
      border: border
    }

    {prepped, cache}
  end

  defp inline({:inline, rows}), do: rows
  defp inline(_ref), do: nil

  defp rows_source(nil), do: %{}
  defp rows_source(m) when is_map(m), do: m
  defp rows_source(t) when is_tuple(t), do: t
  defp rows_source(list) when is_list(list), do: Map.new(list)

  defp fetch_row(t, n) when is_tuple(t), do: if(n < tuple_size(t), do: elem(t, n))
  defp fetch_row(m, n), do: Map.get(m, n)

  defp prep_border(nil, _, cache, _), do: {nil, cache}

  defp prep_border(%{rect: r, edges: edges, title: title}, focus?, cache, theme) do
    left? = :left in edges
    right? = :right in edges
    key = {r.w, left?, right?, title, focus?}

    pieces = Map.get_lazy(cache, key, fn -> border_pieces(key, theme) end)

    border = %{
      ox: r.x,
      oy: r.y,
      ow: r.w,
      oh: r.h,
      left?: left?,
      right?: right?,
      top?: :top in edges,
      bottom?: :bottom in edges
    }

    {Map.merge(border, pieces), Map.put(cache, key, pieces)}
  end

  defp border_pieces({w, left?, right?, title, focus?}, theme) do
    style = Theme.border_style(theme, focus?)
    g = Theme.glyphs(theme)

    %{
      v: Cells.text(g.v, style),
      top_row: hline(w, left?, right?, {g.tl, g.tr}, g.h, title, style),
      bottom_row: hline(w, left?, right?, {g.bl, g.br}, g.h, nil, style)
    }
  end

  defp hline(w, left?, right?, {l, r}, h, title, style) do
    lc = if left? and w > 1, do: [l], else: []
    rc = if right? and w > 1, do: [r], else: []
    mid = w - length(lc) - length(rc)
    t = if title in [nil, ""], do: nil, else: Cells.text(title, style)
    t = t && Cells.fit(t, 0, min(Cell.cols(t), mid))
    used = if t, do: Cell.cols(t), else: 0
    fill = Cells.repeat(h, mid - used, style)

    Cells.concat(
      Enum.map(lc, &Cells.text(&1, style)) ++
        List.wrap(t) ++ [fill] ++ Enum.map(rc, &Cells.text(&1, style))
    )
  end

  defp pane_segs(p, y), do: border_segs(p.border, y) ++ content_segs(p, y)

  defp border_segs(nil, _), do: []

  defp border_segs(b, y) do
    cond do
      y < b.oy or y >= b.oy + b.oh -> []
      b.top? and y == b.oy -> [{b.ox, b.ow, b.top_row}]
      b.bottom? and y == b.oy + b.oh - 1 -> [{b.ox, b.ow, b.bottom_row}]
      true -> side(b.left?, b.ox, b.v) ++ side(b.right?, b.ox + b.ow - 1, b.v)
    end
  end

  defp side(true, x, v), do: [{x, 1, v}]
  defp side(false, _, _), do: []

  defp content_segs(p, y) when y < p.cy or y >= p.cy + p.ch, do: []

  defp content_segs(p, y) do
    {lo, hi} = visible(p.border, y, p.cx, p.cx + p.cw)

    if lo >= hi do
      []
    else
      row = content_row(p, y - p.cy)
      [{lo, hi - lo, if(hi - lo == p.cw, do: row, else: Cells.fit(row, lo - p.cx, hi - lo))}]
    end
  end

  # columns [lo, hi) of the content not covered by this pane's border
  defp visible(nil, _, lo, hi), do: {lo, hi}

  defp visible(b, y, lo, hi) do
    cond do
      y < b.oy or y >= b.oy + b.oh -> {lo, hi}
      hrow?(b, y) -> {lo, lo}
      true -> {trim(b.left?, lo, &max/2, b.ox + 1), trim(b.right?, hi, &min/2, b.ox + b.ow - 1)}
    end
  end

  defp hrow?(b, y), do: (b.top? and y == b.oy) or (b.bottom? and y == b.oy + b.oh - 1)

  defp trim(true, v, f, bound), do: f.(v, bound)
  defp trim(false, v, _, _), do: v

  defp content_row(p, n) do
    row =
      case fetch_row(p.src, n) do
        nil -> Cell.blank_row(p.cw)
        r -> if Cells.exact?(r, p.cw), do: r, else: Cells.fit(r, 0, p.cw)
      end

    Enum.reduce(p.overlays, row, fn o, row ->
      case overlay_change(o, n, p.cw) do
        nil -> row
        {x, w, changes} -> Cells.restyle(row, x, w, changes)
      end
    end)
  end

  defp overlay_change(%{kind: :selection, args: a}, y, cw),
    do: span(a.from, a.to, y, cw, add_attrs: [:inverse])

  defp overlay_change(%{kind: :link_hover, args: a}, y, cw),
    do: span(a.from, a.to, y, cw, underline: :single)

  # ponytail: decodes every row of a dimmed pane; raw attr-bit patching if it shows in benchmarks
  defp overlay_change(%{kind: :dim}, _y, cw), do: {0, cw, add_attrs: [:faint]}
  defp overlay_change(_scrollbar_or_unknown, _y, _cw), do: nil

  defp span(from, to, y, cw, changes) do
    {{fx, fy}, {tx, ty}} = if swap?(from, to), do: {to, from}, else: {from, to}

    if y >= fy and y <= ty do
      xs = if y == fy, do: fx, else: 0
      xe = min(if(y == ty, do: tx, else: cw - 1), cw - 1)
      if xs <= xe, do: {xs, xe - xs + 1, changes}
    end
  end

  defp swap?({fx, fy}, {tx, ty}), do: {fy, fx} > {ty, tx}

  # chrome

  defp status_rows(nil, _), do: %{}

  defp status_rows(node, theme) do
    node
    |> statuses()
    |> Enum.flat_map(&status_segs(&1, theme))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp statuses(%Node{role: :status} = n), do: [n]
  defp statuses(%Node{children: cs}), do: Enum.flat_map(cs, &statuses/1)

  defp status_segs(%Node{rect: nil}, _), do: []

  defp status_segs(%Node{rect: r, children: children}, theme) do
    base = Theme.style(theme, :default)
    {hints, rest} = Enum.split_with(children, &(&1.id == :hint))
    left = rest |> Enum.flat_map(&pieces(&1, theme)) |> join(base)
    hint = hints |> List.last() |> hint_piece(theme)
    hw = if hint, do: Cell.cols(hint), else: 0

    first =
      if hint && hw <= r.w do
        clipped = clip(left, r.w - hw, base)
        Cells.concat([clipped, hint])
      else
        clip(left, r.w, base)
      end

    for y <- r.y..(r.y + r.h - 1)//1 do
      {y, {r.x, r.w, if(y == r.y, do: first, else: Cells.blank(r.w, base))}}
    end
  end

  defp hint_piece(nil, _), do: nil
  defp hint_piece(%Node{text: t}, _) when t in [nil, ""], do: nil
  defp hint_piece(%Node{text: t, token: tok}, theme), do: Cells.text(t, Theme.style(theme, tok))

  defp pieces(%Node{role: :text, text: t}, _) when t in [nil, ""], do: []

  defp pieces(%Node{role: :text, text: t, token: tok}, theme),
    do: [Cells.text(t, Theme.style(theme, tok))]

  defp pieces(%Node{role: :tab} = n, theme), do: [tab_piece(n, theme)]
  defp pieces(%Node{role: :divider}, _), do: []

  defp pieces(%Node{role: :tabs, children: tabs}, theme),
    do: Enum.map(tabs, &tab_piece(&1, theme))

  defp pieces(%Node{children: cs}, theme), do: Enum.flat_map(cs, &pieces(&1, theme))

  defp tab_piece(%Node{text: name, props: props}, theme) do
    token = if Map.get(props, :active), do: :inverse, else: :muted
    Cells.text(" #{Map.get(props, :index)}:#{name} ", Theme.style(theme, token))
  end

  defp join([], _), do: Cell.blank_row(0)

  defp join(pieces, base) do
    pieces |> Enum.intersperse(Cells.blank(1, base)) |> Cells.concat()
  end

  # exactly w cells: clip long rows, pad short ones with the status background
  defp clip(row, w, base) do
    n = Cell.cols(row)

    cond do
      n > w -> Cells.fit(row, 0, w)
      n == w -> row
      true -> Cells.concat([row, Cells.blank(w - n, base)])
    end
  end
end
