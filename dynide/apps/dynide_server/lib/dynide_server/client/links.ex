defmodule DynideServer.Client.Links do
  @moduledoc """
  Pure link extent under a pane cell (herdr link hover and ctrl+click).

  `at(rows, w, x, y)` takes the pane's tuple of packed rows (`Pane.Rows`), its width
  and a pane-relative cell, and returns the link there with an inclusive stream
  range (`from`/`to` may be on different rows), or `nil`:

    * OSC 8: `%{id: id, from, to}`, the run of cells carrying the same non-zero link
      id, wrapping across rows. A blank cell right after a wide cell (its tail)
      inherits that cell's link. A run longer than 8191 cells gives `nil`. The URI is
      not known here (resolve it with `Native.Vt.link_at/3`); any scheme is returned,
      and the caller checks `safe?/1` before opening.
    * Text: `%{id: 0, url: url, from, to}`, an `http://`/`https://` URL with herdr's
      trims (`DynideServer.Client.Words.url_span/2`) inside the whitespace-bounded
      token under the cell. Soft wrap is a heuristic, as packed rows carry no wrap
      flag: the token continues onto the next row while the row's last cell is
      non-blank, and back onto the previous row while this row's first cell and the
      previous row's last cell are non-blank. The token walk is capped at 8192 cells.

  Cells are read straight from the packed records (O(1) per cell); only a row with
  overflow clusters is decoded.
  """

  import DynideScene.Cell, only: [record: 7, overflow?: 1]
  alias DynideScene.Cell
  alias DynideServer.Client.Words

  @osc8_cap 8191
  @text_cap 8192

  @type pos :: {non_neg_integer, non_neg_integer}
  @type t ::
          %{id: pos_integer, from: pos, to: pos}
          | %{id: 0, url: binary, from: pos, to: pos}

  @doc "True when `url` may be opened: `http://` or `https://` only."
  @spec safe?(binary) :: boolean
  def safe?(url), do: String.starts_with?(url, ["http://", "https://"])

  @spec at(tuple, non_neg_integer, integer, integer) :: t | nil
  def at(rows, w, x, y) when x >= 0 and y >= 0 and x < w and y < tuple_size(rows) do
    case link(rows, x, y) do
      0 -> text_url(rows, w, x, y)
      id -> osc8(rows, w, x, y, id)
    end
  end

  def at(_, _, _, _), do: nil

  # OSC 8

  defp osc8(rows, w, x, y, id) do
    total = w * tuple_size(rows)
    clicked = y * w + x
    match? = fn i -> link(rows, rem(i, w), div(i, w)) == id end

    with {start, left} when left >= 0 <- walk(clicked, -1, total, match?, @osc8_cap),
         {stop, right} when right >= 0 <- walk(clicked, 1, total, match?, left) do
      %{id: id, from: {rem(start, w), div(start, w)}, to: {rem(stop, w), div(stop, w)}}
    else
      _ -> nil
    end
  end

  # Extends from i by step while match? holds, spending one of `budget` per cell;
  # returns the last matching index and the budget left (negative = over the cap).
  defp walk(i, step, total, match?, budget) do
    n = i + step

    cond do
      n < 0 or n >= total or not match?.(n) -> {i, budget}
      budget == 0 -> {i, -1}
      true -> walk(n, step, total, match?, budget - 1)
    end
  end

  # The glyph is decoded only for a link-0 cell right after a wide cell.
  defp link(rows, x, y) do
    case meta(rows, x, y) do
      {_, l} when l != 0 or x == 0 -> l
      {width, 0} -> inherited(rows, x, y, width, meta(rows, x - 1, y))
    end
  end

  defp inherited(rows, x, y, width, {2, prev}),
    do: if(width == 0 or blank_at?(rows, x, y), do: prev, else: 0)

  defp inherited(_rows, _x, _y, _width, _prev), do: 0

  defp blank_at?(rows, x, y), do: Words.blank?(elem(cell(rows, x, y), 0))

  # {width, link} straight from the record, no glyph decoding
  defp meta(rows, x, y) do
    row = elem(rows, y)

    if x >= Cell.cols(row) do
      {1, 0}
    else
      record(_glyph, _fg, _bg, _ul, _attrs, width, link) =
        binary_part(row, x * Cell.size(), Cell.size())

      {width, link}
    end
  end

  # text URLs

  defp text_url(rows, w, x, y) do
    x = if x > 0 and elem(meta(rows, x, y), 0) == 0, do: x - 1, else: x
    here = text_cell(rows, x, y)

    if Words.blank?(elem(here, 0)) do
      nil
    else
      left = collect(rows, w, prev(rows, w, x, y), &prev/4, @text_cap - 1, [])
      right = collect(rows, w, next(rows, w, x, y), &next/4, @text_cap - 1 - length(left), [])
      token = List.to_tuple(left ++ [here | Enum.reverse(right)])

      case Words.url_span(token, length(left)) do
        nil -> nil
        {s, e} -> url_result(token, s, e)
      end
    end
  end

  defp url_result(token, s, e) do
    {_, x1, _, y1} = elem(token, s)
    {_, _, x2, y2} = elem(token, e)
    url = Enum.map_join(s..e, &elem(elem(token, &1), 0))
    %{id: 0, url: url, from: {x1, y1}, to: {x2, y2}}
  end

  # Collects non-blank text cells from pos along step; `prev` builds in order, `next`
  # in reverse (both prepend).
  defp collect(_rows, _w, nil, _step, _budget, acc), do: acc
  defp collect(_rows, _w, _pos, _step, 0, acc), do: acc

  defp collect(rows, w, {x, y}, step, budget, acc) do
    tc = text_cell(rows, x, y)

    if Words.blank?(elem(tc, 0)),
      do: acc,
      else: collect(rows, w, step.(rows, w, x, y), step, budget - 1, [tc | acc])
  end

  defp prev(rows, w, x, y) do
    cond do
      x > 0 -> head(rows, x - 1, y)
      y > 0 -> head(rows, w - 1, y - 1)
      true -> nil
    end
  end

  defp next(rows, w, x, y) do
    nx = if elem(meta(rows, x, y), 0) == 2, do: x + 2, else: x + 1

    cond do
      nx < w -> {nx, y}
      y + 1 < tuple_size(rows) -> {0, y + 1}
      true -> nil
    end
  end

  defp head(rows, x, y) do
    if x > 0 and elem(meta(rows, x, y), 0) == 0, do: {x - 1, y}, else: {x, y}
  end

  defp text_cell(rows, x, y) do
    {g, width, _} = cell(rows, x, y)
    {if(g == "", do: " ", else: g), x, x + max(width, 1) - 1, y}
  end

  # one cell: {glyph, width, link}

  defp cell(rows, x, y) do
    row = elem(rows, y)

    if x >= Cell.cols(row) do
      {"", 1, 0}
    else
      record(glyph, _fg, _bg, _ul, _attrs, width, link) =
        binary_part(row, x * Cell.size(), Cell.size())

      {decode_glyph(row, x, glyph), width, link}
    end
  end

  defp decode_glyph(row, x, glyph) when overflow?(glyph),
    do: row |> Cell.decode_row() |> Enum.at(x) |> Map.fetch!(:glyph)

  defp decode_glyph(_row, _x, glyph), do: hd(:binary.split(glyph, <<0>>))
end
