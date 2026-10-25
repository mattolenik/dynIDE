defmodule HerdrTerm.Client.Term.Render.Graphics do
  @moduledoc """
  Pure kitty placement pass, run after `Render.Compose`: the scene's pane placements
  (`HerdrScene.Scene.Graphic`) become `HerdrTerm.Kernel.Blit` graphics ops.

    * `place/3` - each placement clipped to its pane's content rect (herdr's
      `clipped_placement`: left/top clip in cells, the crop is clip cells * cell px
      scaled by source px over rendered px, offsets kept only on unclipped edges), then
      cut around occluders (herdr's `Occlusion`): top-layer chrome (`chrome.top`), the
      pane's own overlays selection, link hover, search match, copy cursor and scrollbar,
      and the outer rects (border rect, else rect) of the `:popup` panes drawn over it:
      every popup over a `:base` pane, later popups in `scene.panes` over a popup.
      Pieces use absolute source boundaries, so neighbours share exact source edges. At
      most 32 extra pieces per frame; past that an occluded placement hides whole.
      A dimming modal (`chrome.dim`) hides every `:base` placement (popups draw over the
      dim, so theirs stay); an unknown cell size hides everything.
    * `diff/4` - ops against the host cache: stale placements and unused images deleted,
      missing images uploaded, then every piece placed (replayed each frame: the host
      drops placements when the cells under them are rewritten).
    * `labels/2` - `[image WxH]` in the first visible row of a withheld image (the server
      sent `data: nil`).

  Host ids (herdr's ranges, collisions not detected): image
  `10_000 + phash2({pane_id, image_id, fp}, 900_000)`, placement
  `1 + phash2({pane_id, image_id, placement, piece}, 900_000)`.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene
  alias HerdrScene.Scene.Overlay
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Theme

  @max_extra_pieces 32
  @file_min_bytes 32_768
  @remote_env ~w(SSH_CONNECTION SSH_TTY SSH_CLIENT TMUX STY HERDR_PANE_ID HERDR_PANE_RUNTIME_ID)

  @type key :: {pos_integer, pos_integer, non_neg_integer}
  @type piece :: %{
          key: key,
          placement: pos_integer,
          piece: non_neg_integer,
          x: non_neg_integer,
          y: non_neg_integer,
          cols: pos_integer,
          rows: pos_integer,
          src: {non_neg_integer, non_neg_integer, pos_integer, pos_integer},
          off: {non_neg_integer, non_neg_integer},
          z: integer
        }
  @type cache :: %{images: %{pos_integer => key}, placements: MapSet.t()}
  @type images :: %{key => HerdrScene.Scene.Graphic.image() | nil}

  @doc "An empty host cache."
  @spec empty() :: cache
  def empty, do: %{images: %{}, placements: MapSet.new()}

  @doc """
  The whole pass for one frame: pieces, ops and the new cache, labels spliced into
  `frame` (composed `{y, row}` rows). `ctx`: `cell_px`, `cache`, `images`, `file?`, `theme`.
  """
  @spec run([{non_neg_integer, Cell.row()}], Scene.t(), map, map) ::
          {[{non_neg_integer, Cell.row()}], [HerdrTerm.Kernel.Blit.graphics_op()], cache}
  def run(frame, scene, chrome, ctx) do
    pieces = place(scene, chrome, ctx.cell_px)
    {ops, cache} = diff(ctx.cache, pieces, ctx.images, %{file?: ctx.file?})
    {splice(frame, labels(pieces, ctx.images), ctx.theme), ops, cache}
  end

  # placement

  @doc "Visible pieces of every placement in screen cells (see the moduledoc)."
  @spec place(Scene.t(), map, {pos_integer, pos_integer} | nil) :: [piece]
  def place(_scene, _chrome, nil), do: []

  def place(%Scene{panes: panes}, chrome, cell) do
    dim? = Map.get(chrome, :dim, false)

    clipped =
      for {p, over} <- Enum.zip(panes, popups_over(panes)),
          not dim? or p.layer == :popup,
          g <- p.graphics,
          c = clip(p, g, cell),
          do: {c, p, over}

    case clipped do
      [] ->
        []

      clipped ->
        top = top_rects(chrome.top)

        clipped
        |> Enum.map(fn {c, p, over} -> {c, top ++ overlay_rects(p) ++ over} end)
        |> occlude()
        |> pieces(cell)
    end
  end

  # per pane, the outer rects of the popups drawn over it
  defp popups_over(panes) do
    case for(%{layer: :popup} = p <- panes, do: outer(p)) do
      [] ->
        Stream.cycle([[]])

      popups ->
        panes
        |> Enum.map_reduce(popups, fn
          %{layer: :popup}, [_ | later] -> {later, later}
          _base, left -> {popups, left}
        end)
        |> elem(0)
    end
  end

  defp outer(%{border: %{rect: r}}), do: {r.x, r.y, r.w, r.h}
  defp outer(%{rect: r}), do: {r.x, r.y, r.w, r.h}

  defp clip(%{id: id, rect: r}, g, cell) do
    lclip = max(-g.x, 0)
    tclip = max(-g.y, 0)
    vx = max(g.x, 0)
    vy = max(g.y, 0)
    cols = min(g.cols - lclip, r.w - vx)
    rows = min(g.rows - tclip, r.h - vy)

    with true <- vx < r.w and vy < r.h and cols > 0 and rows > 0,
         {_, _, sw, sh} = src when sw > 0 and sh > 0 <-
           crop(g, {lclip, tclip}, {cols, rows}, cell) do
      {image_id, fp} = g.image

      %{
        key: {id, image_id, fp},
        placement: g.placement,
        x: r.x + vx,
        y: r.y + vy,
        cols: cols,
        rows: rows,
        src: src,
        off: {if(lclip == 0, do: g.x_off, else: 0), if(tclip == 0, do: g.y_off, else: 0)},
        z: g.z
      }
    else
      _ -> nil
    end
  end

  # the source rect left after clipping `clip` cells off the left/top, `vis` cells shown
  defp crop(g, {lclip, tclip}, {cols, rows}, {cw, ch}) do
    {img_w, img_h} = g.size
    {sx, sy, sw, sh} = g.src
    {pw, ph} = g.px
    {sx, sw} = crop_axis(sx, sw, img_w, pw, g.cols, lclip, cols, cw)
    {sy, sh} = crop_axis(sy, sh, img_h, ph, g.rows, tclip, rows, ch)
    {sx, sy, sw, sh}
  end

  defp crop_axis(s, len, img, px, cells, clip, vis, cell) do
    len = if len == 0, do: img, else: len
    px = max(max(px, cells * cell), 1)
    s = s + scale(clip * cell, len, px)
    {s, min(max(scale(vis * cell, len, px), 1), img - s)}
  end

  defp scale(value, source, dest), do: div(value * source, max(dest, 1))

  # occluders: screen rects `{x, y, w, h}`

  defp overlay_rects(p), do: for(o <- p.overlays, rect <- overlay_rects(o, p.rect), do: rect)

  # one rect per row segment, merged down while the next row has the same span
  defp top_rects(top) when map_size(top) == 0, do: []

  defp top_rects(top) do
    for({y, segs} <- top, {x, w, _} <- segs, w > 0, do: {x, y, w, 1})
    |> Enum.sort_by(fn {x, y, w, _} -> {x, w, y} end)
    |> Enum.reduce([], fn
      {x, y, w, 1}, [{x, y0, w, h} | rest] when y0 + h == y -> [{x, y0, w, h + 1} | rest]
      rect, acc -> [rect | acc]
    end)
  end

  defp overlay_rects(%Overlay{kind: kind, args: a}, r)
       when kind in [:selection, :link_hover, :search_match],
       do: range_rects(a.from, a.to, r)

  defp overlay_rects(%Overlay{kind: :copy_cursor, args: %{at: {x, y}}}, r),
    do: [{r.x + x, r.y + y, 1, 1}]

  defp overlay_rects(%Overlay{kind: :scrollbar}, r), do: [{r.x + r.w - 1, r.y, 1, r.h}]
  defp overlay_rects(_other, _r), do: []

  # a stream range (as `Render.Overlays` draws it): first row from fx, middle rows full,
  # last row to tx
  defp range_rects({fx, fy} = from, {tx, ty} = to, r) do
    if {fy, fx} > {ty, tx} do
      range_rects(to, from, r)
    else
      last = r.w - 1

      if fy == ty do
        [{r.x + fx, r.y + fy, min(tx, last) - fx + 1, 1}]
      else
        [
          {r.x + fx, r.y + fy, last - fx + 1, 1},
          {r.x, r.y + fy + 1, r.w, ty - fy - 1},
          {r.x, r.y + ty, min(tx, last) + 1, 1}
        ]
      end
      |> Enum.filter(fn {_, _, w, h} -> w > 0 and h > 0 end)
    end
  end

  # `[{clipped, rects}]` to `[{clipped, [grid piece]}]`; grid pieces
  # `{col, row, cols, rows}` relative to it
  defp occlude(clipped) do
    result =
      Enum.reduce_while(clipped, {[], @max_extra_pieces}, fn {c, rects}, {acc, budget} ->
        case visible(c, rects, budget + 1) do
          :over -> {:halt, :over}
          found -> {:cont, {[{c, found} | acc], budget - max(length(found) - 1, 0)}}
        end
      end)

    case result do
      {acc, _budget} ->
        Enum.reverse(acc)

      :over ->
        for {c, rects} <- clipped,
            do: {c, if(visible(c, rects, 1) == [whole(c)], do: [whole(c)], else: [])}
    end
  end

  defp whole(c), do: {0, 0, c.cols, c.rows}

  defp visible(c, rects, limit) do
    Enum.reduce_while(rects, [whole(c)], fn rect, pieces ->
      case cut(pieces, c, rect) do
        [] -> {:halt, []}
        pieces when length(pieces) > limit -> {:halt, :over}
        pieces -> {:cont, pieces}
      end
    end)
  end

  defp cut(pieces, c, {rx, ry, rw, rh}) do
    with {c0, c1} <- covered(rx, rw, c.x, c.cols),
         {r0, r1} <- covered(ry, rh, c.y, c.rows),
         do: Enum.flat_map(pieces, &subtract(&1, c0, c1, r0, r1)),
         else: (nil -> pieces)
  end

  defp covered(start, len, at, cells) do
    first = max(start - at, 0)
    last = min(start + len - at, cells)
    if first < last, do: {first, last}
  end

  defp subtract({col, row, cols, rows} = p, c0, c1, r0, r1) do
    right = col + cols
    bottom = row + rows

    if c1 <= col or c0 >= right or r1 <= row or r0 >= bottom do
      [p]
    else
      mt = max(r0, row)
      mb = min(r1, bottom)

      for {l, t, rr, b} <- [
            {col, row, right, mt},
            {col, mb, right, bottom},
            {col, mt, max(c0, col), mb},
            {min(c1, right), mt, right, mb}
          ],
          l < rr and t < b,
          do: {l, t, rr - l, b - t}
    end
  end

  defp pieces(occluded, {cw, ch}) do
    for {c, grid} <- occluded, {{col, row, cols, rows}, i} <- Enum.with_index(grid) do
      {sx, sy, sw, sh} = c.src
      {xo, yo} = c.off
      {px, pw} = span(col, cols, c.cols, cw, xo, sw)
      {py, ph} = span(row, rows, c.rows, ch, yo, sh)

      %{
        c
        | x: c.x + col,
          y: c.y + row,
          cols: cols,
          rows: rows,
          src: {sx + px, sy + py, pw, ph},
          off: {if(col == 0, do: xo, else: 0), if(row == 0, do: yo, else: 0)}
      }
      |> Map.put(:piece, i)
    end
  end

  # herdr's `piece_source_span`: the source px shown in cells [start, start + cells)
  defp span(start, cells, total, cell_px, offset, len) do
    display = total * cell_px
    offset = min(offset, max(display - 1, 0))

    edge = fn cell ->
      div((max(cell * cell_px, offset) - offset) * len, max(display - offset, 1))
    end

    {a, b} = {edge.(start), edge.(start + cells)}
    # an upscaled sliver still needs one source px
    if b > a, do: {a, b - a}, else: {min(a, max(len - 1, 0)), 1}
  end

  # host ops

  @doc "Ops for `pieces` against `cache`, and the new cache (see the moduledoc)."
  @spec diff(cache, [piece], images, %{file?: boolean}) ::
          {[HerdrTerm.Kernel.Blit.graphics_op()], cache}
  def diff(cache, pieces, images, opts) do
    shown =
      for %{key: key} = p <- pieces, image = drawable(images, key), do: {p, image, image_id(key)}

    want = Map.new(shown, fn {p, _, id} -> {id, p.key} end)
    places = for {p, _, id} <- shown, do: {id, placement_id(p)}
    placements = MapSet.new(places)

    # ponytail: no offscreen retention, an image no visible piece uses is deleted and
    # re-uploaded when it comes back (herdr keeps 16 / 64 MiB): a tab switch, scroll-off
    # or a dimming modal (which hides every placement) costs a full re-upload of each
    # image on close; add an LRU if it shows
    deletes =
      for(
        {id, p} <- Enum.sort(cache.placements),
        not MapSet.member?(placements, {id, p}),
        do: {:delete_placement, id, p}
      ) ++
        for {id, _} <- Enum.sort(cache.images),
            not Map.has_key?(want, id),
            do: {:delete_image, id}

    {uploads, _} =
      Enum.flat_map_reduce(shown, cache.images, fn {_, image, id}, on_host ->
        if Map.has_key?(on_host, id),
          do: {[], on_host},
          else: {[upload(id, image, opts)], Map.put(on_host, id, true)}
      end)

    ops =
      for {{p, _, id}, {_, pid}} <- Enum.zip(shown, places),
          do:
            {:place,
             %{
               id: id,
               placement: pid,
               x: p.x,
               y: p.y,
               cols: p.cols,
               rows: p.rows,
               src: p.src,
               off: p.off,
               z: p.z
             }}

    {deletes ++ uploads ++ ops, %{images: want, placements: placements}}
  end

  defp drawable(images, key) do
    case Map.get(images, key) do
      %{data: <<_, _::binary>>} = image -> image
      _ -> nil
    end
  end

  defp upload(id, image, opts) do
    medium = if opts.file? and byte_size(image.data) > @file_min_bytes, do: :file, else: :direct

    {:upload,
     %{
       id: id,
       format: image.format,
       width: image.width,
       height: image.height,
       data: image.data,
       medium: medium
     }}
  end

  defp image_id({_pane, _image, _fp} = key), do: 10_000 + :erlang.phash2(key, 900_000)

  defp placement_id(%{key: {pane, image, _fp}, placement: p, piece: i}),
    do: 1 + :erlang.phash2({pane, image, p, i}, 900_000)

  # labels

  @doc "`{x, y, text}` per withheld image placement, in its first visible row."
  @spec labels([piece], images) :: [{non_neg_integer, non_neg_integer, binary}]
  def labels(pieces, images) do
    pieces
    |> Enum.filter(&match?(%{data: nil}, Map.get(images, &1.key)))
    |> Enum.group_by(&{&1.key, &1.placement})
    |> Enum.map(fn {{key, _}, ps} ->
      p = Enum.min_by(ps, &{&1.y, &1.x})
      %{width: w, height: h} = Map.fetch!(images, key)
      {p.x, p.y, String.slice("[image #{w}x#{h}]", 0, p.cols)}
    end)
    |> Enum.sort()
  end

  defp splice(frame, [], _theme), do: frame

  defp splice(frame, labels, theme) do
    by_row = Enum.group_by(labels, &elem(&1, 1))
    style = Theme.style(theme, :muted)

    Enum.map(frame, fn {y, row} = line ->
      case Map.get(by_row, y) do
        nil ->
          line

        ls ->
          {y,
           Enum.reduce(ls, row, fn {x, _, text}, row ->
             piece = Cells.text(text, style)
             w = Cell.cols(piece)

             Cell.concat([
               Cells.fit(row, 0, x),
               piece,
               Cells.fit(row, x + w, Cell.cols(row) - x - w)
             ])
           end)}
      end
    end)
  end

  # transport

  @doc """
  Whether file-backed uploads may be tried (herdr's gate): the host is Ghostty and the
  client is not over ssh, inside tmux/screen or inside a herdr pane.
  """
  @spec file_transport?(%{binary => binary}) :: boolean
  def file_transport?(env),
    do: env["TERM_PROGRAM"] == "ghostty" and not Enum.any?(@remote_env, &Map.has_key?(env, &1))
end
