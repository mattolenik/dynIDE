defmodule HerdrTerm.Cells do
  @moduledoc """
  Renderer helpers over the packed cell format (`HerdrScene.Cell`). Chrome
  only: pane cells arrive from the kernel with their widths. Slicing and
  joining go through `HerdrScene.Cell.slice/3` and `concat/1`, never raw
  binary ops, because rows may carry an overflow trailer.
  """

  alias HerdrScene.Cell

  @wide [
    0x1100..0x115F,
    0x2E80..0xA4CF,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE30..0xFE4F,
    0xFF00..0xFF60,
    0xFFE0..0xFFE6,
    0x1F300..0x1F64F,
    0x1F900..0x1F9FF,
    0x20000..0x3FFFD
  ]

  @doc "A cell template with an empty glyph. Keys: `fg:`, `bg:`, `attrs:`, `underline:`."
  @spec style(keyword) :: Cell.t()
  def style(opts) do
    %Cell{
      fg: Keyword.get(opts, :fg, :default),
      bg: Keyword.get(opts, :bg, :default),
      attrs: Keyword.get(opts, :attrs, []),
      underline: Keyword.get(opts, :underline, :none)
    }
  end

  @doc "One cell per grapheme; wide graphemes get a width-0 tail cell."
  @spec text(binary, Cell.t()) :: Cell.row()
  def text(str, %Cell{} = style) do
    str
    |> String.graphemes()
    |> Enum.flat_map(fn g ->
      <<cp::utf8, _::binary>> = g

      if Enum.any?(@wide, &(cp in &1)),
        do: [%{style | glyph: g, width: 2}, %{style | glyph: "", width: 0}],
        else: [%{style | glyph: g, width: 1}]
    end)
    |> Cell.encode_row()
  end

  @doc "`n` blank cells carrying the style's colours and attributes."
  @spec blank(non_neg_integer, Cell.t()) :: Cell.row()
  def blank(n, %Cell{} = style),
    do: Cell.encode_row(List.duplicate(%{style | glyph: "", width: 1}, n))

  @doc "Columns `x..x+w-1`, blank-padded past the end, never splitting a wide char."
  @spec fit(Cell.row(), non_neg_integer, non_neg_integer) :: Cell.row()
  def fit(row, x, w) do
    n = max(min(w, Cell.cols(row) - x), 0)
    pad = w - n

    if n == 0 do
      blank(w, %Cell{})
    else
      piece = Cell.slice(row, x, n)
      piece = if pad == 0 and edge_ok?(piece), do: piece, else: fix_edges(piece)
      if pad == 0, do: piece, else: Cell.concat([piece, blank(pad, %Cell{})])
    end
  end

  defp edge_ok?(piece) do
    cells = Cell.records(piece)
    last = byte_size(cells) - 32
    <<_::binary-size(26), first_w, _::binary>> = cells
    <<_::binary-size(^last), _::binary-size(26), last_w, _::binary>> = cells
    first_w != 0 and last_w != 2
  end

  defp fix_edges(piece) do
    piece |> Cell.decode_row() |> fix_head() |> fix_last() |> Cell.encode_row()
  end

  defp fix_head([%Cell{width: 0} = c | rest]), do: [%{c | width: 1} | rest]
  defp fix_head(cells), do: cells

  defp fix_last(cells) do
    case List.last(cells) do
      %Cell{width: 2} = c -> List.replace_at(cells, -1, %{c | glyph: "", width: 1})
      _ -> cells
    end
  end

  @doc "Joins rows left to right."
  @spec concat([Cell.row()]) :: Cell.row()
  defdelegate concat(rows), to: Cell

  @doc """
  Changes columns `x..x+w-1`: `add_attrs: [flag]`, `fg:`, `bg:`, `underline:`.
  """
  @spec restyle(Cell.row(), non_neg_integer, non_neg_integer, keyword) :: Cell.row()
  def restyle(row, x, w, changes) do
    row
    |> Cell.decode_row()
    |> Enum.with_index()
    |> Enum.map(fn {c, i} -> if i >= x and i < x + w, do: apply_changes(c, changes), else: c end)
    |> Cell.encode_row()
  end

  defp apply_changes(c, changes) do
    Enum.reduce(changes, c, fn
      {:add_attrs, flags}, c -> %{c | attrs: Enum.uniq(c.attrs ++ flags)}
      {:fg, v}, c -> %{c | fg: v}
      {:bg, v}, c -> %{c | bg: v}
      {:underline, v}, c -> %{c | underline: v}
    end)
  end

  @doc "Row text; width-0 tails skipped, empty glyphs become spaces."
  @spec to_text(Cell.row()) :: binary
  def to_text(row) do
    for %Cell{width: w, glyph: g} <- Cell.decode_row(row), w != 0, into: "" do
      if g == "", do: " ", else: g
    end
  end
end
