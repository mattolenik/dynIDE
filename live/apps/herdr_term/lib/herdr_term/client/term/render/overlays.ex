defmodule HerdrTerm.Client.Term.Render.Overlays do
  @moduledoc """
  Pure pane-overlay rasterizer: restyles one pane content row for the scene's
  semantic overlays (`HerdrScene.Scene.Overlay`). Coordinates are pane-relative and
  inclusive; `from`/`to` ranges are stream ranges (middle rows full width).

    * `:selection` - host bg mixed 28% toward white (dark host) or black (light host),
      fg black or white for contrast, other attributes reset; inverse when the host bg
      is unknown (`Theme.selection_changes/1`)
    * `:link_hover`, `:search_match` - single underline; the current match, and
      `:copy_cursor`, take the `:accent` token's fg and attrs plus bold and inverse
    * `:dim` - faint over the whole row
    * `:scrollbar` - column `w-1` is replaced: track `▕` (faint), thumb `▐` when the
      pane is focused, `▕` (not faint) when not; thumb length
      `round(viewport*h/total)` clamped to `[1, h]`, top
      `round(offset*(h-len)/max(total-viewport, 1))`

  A row no overlay touches is returned as is; a touched row is decoded once.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene.Overlay
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Theme

  @typedoc "Pane geometry: content width and height, and whether the pane has focus."
  @type ctx :: %{w: pos_integer, h: pos_integer, focused: boolean}

  @doc "Row `y` (pane-relative) of a pane, exactly `ctx.w` columns, with `overlays` applied."
  @spec apply(Cell.row(), [Overlay.t()], non_neg_integer, ctx, Theme.t()) :: Cell.row()
  def apply(row, [], _y, _ctx, _theme), do: row

  def apply(row, overlays, y, %{w: w} = ctx, theme) do
    row =
      case for(o <- overlays, s = span(o, y, w, theme), do: s) do
        [] -> row
        spans -> Cells.restyle(row, spans)
      end

    Enum.reduce(overlays, row, fn
      %Overlay{kind: :scrollbar, args: a}, row -> scrollbar(row, a, y, ctx, theme)
      _, row -> row
    end)
  end

  defp span(%Overlay{kind: :selection, args: a}, y, w, theme),
    do: range(a.from, a.to, y, w, Theme.selection_changes(theme))

  defp span(%Overlay{kind: :link_hover, args: a}, y, w, _),
    do: range(a.from, a.to, y, w, underline: :single)

  defp span(%Overlay{kind: :search_match, args: %{current: true} = a}, y, w, theme),
    do: range(a.from, a.to, y, w, accent(theme))

  defp span(%Overlay{kind: :search_match, args: a}, y, w, _),
    do: range(a.from, a.to, y, w, underline: :single)

  defp span(%Overlay{kind: :copy_cursor, args: %{at: {x, cy}}}, y, w, theme)
       when cy == y and x < w,
       do: {x, 1, accent(theme)}

  # ponytail: decodes every row of a dimmed pane; raw attr-bit patching if it shows in benchmarks
  defp span(%Overlay{kind: :dim}, _y, w, _), do: {0, w, add_attrs: [:faint]}
  defp span(_other, _y, _w, _), do: nil

  defp accent(theme) do
    a = Theme.style(theme, :accent)
    [fg: a.fg, add_attrs: a.attrs ++ [:bold, :inverse]]
  end

  defp range(from, to, y, w, changes) do
    {{fx, fy}, {tx, ty}} = if swap?(from, to), do: {to, from}, else: {from, to}

    if y >= fy and y <= ty do
      xs = if y == fy, do: fx, else: 0
      xe = min(if(y == ty, do: tx, else: w - 1), w - 1)
      if xs <= xe, do: {xs, xe - xs + 1, changes}
    end
  end

  defp swap?({fx, fy}, {tx, ty}), do: {fy, fx} > {ty, tx}

  defp scrollbar(row, %{total: total, viewport: vp, offset: off}, y, %{w: w, h: h} = ctx, theme) do
    len = (vp * h / max(total, 1)) |> round() |> max(1) |> min(h)
    top = round(off * (h - len) / max(total - vp, 1))
    thumb? = y >= top and y < top + len

    cell =
      case {thumb?, ctx.focused} do
        {true, true} -> Cells.text("▐", Theme.style(theme, :default))
        {true, false} -> Cells.text("▕", Theme.style(theme, :default))
        {false, _} -> Cells.text("▕", Theme.style(theme, :muted))
      end

    Cells.concat([Cells.fit(row, 0, w - 1), cell])
  end
end
