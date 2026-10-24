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

  @doc "One cell per grapheme; wide graphemes get a width-0 tail cell. Invalid UTF-8 becomes U+FFFD."
  @spec text(binary, Cell.t()) :: Cell.row()
  def text(str, %Cell{} = style) do
    str
    |> String.replace_invalid()
    |> String.graphemes()
    |> Enum.flat_map(fn g ->
      <<cp::utf8, _::binary>> = g

      if wide?(cp),
        do: [%{style | glyph: g, width: 2}, %{style | glyph: "", width: 0}],
        else: [%{style | glyph: g, width: 1}]
    end)
    |> Cell.encode_row()
  end

  # a guard clause per literal range: no runtime Enumerable dispatch per grapheme
  for r <- @wide do
    defp wide?(cp) when cp in unquote(Macro.escape(r)), do: true
  end

  defp wide?(_cp), do: false

  @doc """
  `n` copies of `glyph`, same bytes as `text(String.duplicate(glyph, n), style)`;
  a narrow inline glyph is encoded once and its record repeated.
  """
  @spec repeat(binary, non_neg_integer, Cell.t()) :: Cell.row()
  def repeat(glyph, n, %Cell{} = style) do
    one = text(glyph, style)

    if Cell.plain?(one) and Cell.cols(one) == 1,
      do: :binary.copy(Cell.records(one), n) <> <<0::32-little>>,
      else: text(String.duplicate(glyph, n), style)
  end

  @doc "`n` blank cells carrying the style's colours and attributes."
  @spec blank(non_neg_integer, Cell.t()) :: Cell.row()
  def blank(n, %Cell{} = style),
    do:
      :binary.copy(Cell.records(Cell.encode_row([%{style | glyph: "", width: 1}])), n) <>
        <<0::32>>

  @doc "Columns `x..x+w-1`, blank-padded past the end, never splitting a wide char."
  @spec fit(Cell.row(), non_neg_integer, non_neg_integer) :: Cell.row()
  def fit(row, x, w) do
    n = max(min(w, Cell.cols(row) - x), 0)
    pad = w - n

    if n == 0 do
      Cell.blank_row(w)
    else
      piece = Cell.slice(row, x, n)
      piece = if edge_ok?(piece), do: piece, else: fix_edges(piece)
      if pad == 0, do: piece, else: Cell.concat([piece, Cell.blank_row(pad)])
    end
  end

  @doc "True when `fit(row, 0, w)` would return `row` unchanged: `w > 0` columns, edges whole."
  @spec exact?(Cell.row(), non_neg_integer) :: boolean
  def exact?(row, w), do: w > 0 and Cell.cols(row) == w and edge_ok?(row)

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
  `restyle(row, 0, cols, add_attrs: [:faint])` without decoding: sets the faint bit
  (attrs bit 2, record bytes 24..25) of every record in place; the trailer is kept.
  """
  @spec faint(Cell.row()) :: Cell.row()
  def faint(row) do
    recs = Cell.records(row)
    n = byte_size(recs)

    out =
      for <<head::binary-size(24), attrs::16-little, tail::binary-size(6) <- recs>>,
        into: <<>>,
        do: <<head::binary, Bitwise.bor(attrs, 4)::16-little, tail::binary>>

    out <> binary_part(row, n, byte_size(row) - n)
  end

  @doc """
  Changes columns `x..x+w-1`: `add_attrs: [flag]`, `attrs: [flag]` (replace), `fg:`,
  `bg:`, `ul:`, `underline:`.
  """
  @spec restyle(Cell.row(), non_neg_integer, non_neg_integer, keyword) :: Cell.row()
  def restyle(row, x, w, changes), do: restyle(row, [{x, w, changes}])

  @doc "`restyle/4` for several `{x, w, changes}` spans in order, decoding the row once."
  @spec restyle(Cell.row(), [{non_neg_integer, non_neg_integer, keyword}]) :: Cell.row()
  def restyle(row, spans) do
    row
    |> Cell.decode_row()
    |> Enum.with_index(fn c, i -> Enum.reduce(spans, c, &restyle_cell(&1, &2, i)) end)
    |> Cell.encode_row()
  end

  defp restyle_cell({x, w, changes}, c, i) when i >= x and i < x + w,
    do: apply_changes(c, changes)

  defp restyle_cell(_span, c, _i), do: c

  defp apply_changes(c, changes) do
    Enum.reduce(changes, c, fn
      {:add_attrs, flags}, c -> %{c | attrs: Enum.uniq(c.attrs ++ flags)}
      {:attrs, flags}, c -> %{c | attrs: flags}
      {:ul, v}, c -> %{c | ul: v}
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
