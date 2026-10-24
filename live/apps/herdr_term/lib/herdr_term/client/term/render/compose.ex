defmodule HerdrTerm.Client.Term.Render.Compose do
  @moduledoc """
  Pure rasterizer: a `HerdrScene.Scene` plus packed pane rows becomes full
  screen rows of packed cells. Each screen row is built once as a list of
  pieces (borders, `Cells.fit` slices of pane rows, the chrome layout's base
  segments) and joined once (plain pieces as sub-binaries, else
  `Cells.concat/1`); pane content is never touched per cell except where an
  overlay applies. The chrome layout (`Render.Chrome.layout/3`) is passed in
  precomputed; the forms without it compute it.

  Pieces on a row are expected to be disjoint (borders win over the content
  they overlap; otherwise the leftmost piece wins). Top-layer segments are
  then spliced over the row; with `dim`, every cell outside them gets `:faint`.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene
  alias HerdrScene.Scene.Pane
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome
  alias HerdrTerm.Client.Term.Theme

  @typedoc "Packed rows per pane id; panes absent here fall back to their `{:inline, rows}`."
  @type rows_by_pane :: %{
          pos_integer => tuple | [{non_neg_integer, binary}] | %{non_neg_integer => binary}
        }

  @doc "`{frame/3, cursor/2}`: one guarded call per frame instead of two."
  @spec screen(Scene.t(), rows_by_pane, %{pos_integer => map | nil}, Theme.t()) ::
          {[{non_neg_integer, binary}], {{non_neg_integer, non_neg_integer}, Scene.shape()} | nil}
  def screen(scene, rows_by_pane, cursors, theme),
    do: screen(scene, rows_by_pane, cursors, theme, layout(scene, theme))

  @spec screen(Scene.t(), rows_by_pane, %{pos_integer => map | nil}, Theme.t(), Chrome.t()) ::
          {[{non_neg_integer, binary}], {{non_neg_integer, non_neg_integer}, Scene.shape()} | nil}
  def screen(scene, rows_by_pane, cursors, theme, chrome),
    do: {frame(scene, rows_by_pane, theme, chrome), cursor(scene, cursors)}

  @spec frame(Scene.t(), rows_by_pane, Theme.t()) :: [{non_neg_integer, binary}]
  def frame(scene, rows_by_pane, theme),
    do: frame(scene, rows_by_pane, theme, layout(scene, theme))

  @spec frame(Scene.t(), rows_by_pane, Theme.t(), Chrome.t()) :: [{non_neg_integer, binary}]
  def frame(%Scene{size: %{cols: cols, rows: rows}} = scene, rows_by_pane, theme, chrome) do
    {panes, _cache} =
      Enum.map_reduce(scene.panes, %{}, &prep_pane(&1, &2, scene, rows_by_pane, theme))

    panes
    |> segs_by_row(chrome.base, rows)
    |> Enum.with_index(fn segs, y -> {y, segs |> assemble(cols) |> top(chrome, y, cols)} end)
  end

  defp layout(scene, theme), do: Chrome.layout(scene.chrome, scene.size, theme)

  # per screen row, its segments in pane order then chrome; a pane is visited only
  # for the rows its rect or border spans
  defp segs_by_row(panes, base, rows) do
    spans = for p <- panes, do: {span(p), p}

    for y <- 0..(rows - 1)//1 do
      segs = for {{lo, hi}, p} <- spans, y >= lo and y < hi, seg <- pane_segs(p, y), do: seg
      segs ++ Map.get(base, y, [])
    end
  end

  # top layer: dim the assembled row (ponytail: decodes the row; only while a dimming
  # modal is open), then splice each top segment over it, later segments win
  defp top(row, %{dim: false, top: top}, _y, _cols) when map_size(top) == 0, do: row

  defp top(row, %{dim: dim, top: top}, y, cols) do
    row = if dim, do: Cells.restyle(row, 0, cols, add_attrs: [:faint]), else: row

    Enum.reduce(Map.get(top, y, []), row, fn {x, w, piece}, row ->
      Cell.concat([Cells.fit(row, 0, x), piece, Cells.fit(row, x + w, cols - x - w)])
    end)
  end

  defp span(%{cy: cy, ch: ch, border: nil}), do: {cy, cy + ch}
  defp span(%{cy: cy, ch: ch, border: b}), do: {min(cy, b.oy), max(cy + ch, b.oy + b.oh)}

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
end
