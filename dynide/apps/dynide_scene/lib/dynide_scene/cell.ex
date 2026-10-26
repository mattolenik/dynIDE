defmodule DynideScene.Cell do
  @moduledoc """
  Packed cell format: the row encoding shared by the kernel (`Native.Vt`),
  the server, every client, and the blitter. Spec: `docs/dynide/packed-cells.md`.
  Golden vectors: `test/support/packed_cell_vectors.json` (Rust and Elixir
  both pass them).

  A packed row is `cells <> trailer <> <<trailer_len::32-little>>`. `cells`
  is one fixed 32-byte record per column, so column `x` starts at byte
  `x * 32` and a run of `w` columns is `binary_part(row, x * 32, w * 32)`.

  Record (all integers little-endian):

      byte  0                                  12      16      20      24    26  27  28      32
            +----------------------------------+-------+-------+-------+-----+---+---+-------+
            | glyph: UTF-8, NUL padded (12)    |  fg   |  bg   |  ul   |attrs| w | 0 | link  |
            +----------------------------------+-------+-------+-------+-----+---+---+-------+

  - glyph: the cell's grapheme cluster as UTF-8, NUL padded. All zero is an
    empty cell (renders as a space). A cluster longer than 12 bytes is an
    overflow ref: byte 0 = `0xFF` (never a UTF-8 lead byte), bytes 1..3 zero,
    bytes 4..8 = offset u32, bytes 8..12 = length u32, both into this row's
    trailer.
  - fg, bg, ul (underline colour): u32 `tag <<< 24 ||| payload`. Tag 0 =
    default (payload 0), 1 = palette (payload = index 0..255), 2 = RGB
    (payload = `r <<< 16 ||| g <<< 8 ||| b`).
  - attrs u16: bit 0 bold, 1 italic, 2 faint, 3 blink, 4 inverse,
    5 invisible, 6 strikethrough, 7 overline, bits 8..10 underline style
    (0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed), 11..15 zero.
  - w (width) u8: 1 narrow, 2 wide (the next record is its width-0 tail),
    0 spacer tail of the wide cell to the left (glyph empty).
  - byte 27 reserved, zero.
  - link u32: 0 none, otherwise a per-pane hyperlink id stable for the life
    of the `Vt`; resolve with `Native.Vt.link_at/3`.

  The trailer is the UTF-8 bytes of overflow clusters, concatenated in
  column order with no separators or dedup. Rows without overflow end in
  `<<0::32>>`. Encoding is canonical: a cluster of 12 bytes or fewer is
  always inline, so two rows are equal iff their binaries are equal.
  `slice/3` and `concat/1` are the only sanctioned way to cut and join rows:
  they rebuild the trailer when overflow refs are present and take a
  plain-binary fast path otherwise.
  """

  import Bitwise

  @size 32
  @glyph_bytes 12
  @overflow 0xFF

  @flags [:bold, :italic, :faint, :blink, :inverse, :invisible, :strikethrough, :overline]
  @underlines [:none, :single, :double, :curly, :dotted, :dashed]

  defstruct glyph: "",
            fg: :default,
            bg: :default,
            ul: :default,
            attrs: [],
            underline: :none,
            width: 1,
            link: 0

  @type color :: :default | {:palette, 0..255} | {:rgb, 0..255, 0..255, 0..255}
  @type flag ::
          :bold | :italic | :faint | :blink | :inverse | :invisible | :strikethrough | :overline
  @type underline :: :none | :single | :double | :curly | :dotted | :dashed
  @type t :: %__MODULE__{
          glyph: binary,
          fg: color,
          bg: color,
          ul: color,
          attrs: [flag],
          underline: underline,
          width: 0..2,
          link: non_neg_integer
        }
  @typedoc "A packed row: records, trailer, trailer length."
  @type row :: binary

  @doc "Bytes per record."
  defmacro size, do: @size

  @doc """
  Binary pattern for one raw record, usable in matches and constructors:

      <<record(glyph, fg, bg, ul, attrs, width, link), rest::binary>> = cells

  `glyph` is the raw 12 bytes (may be an overflow ref); colours are the raw
  u32s. Use `decode_row/1` when you need resolved cells.
  """
  defmacro record(glyph, fg, bg, ul, attrs, width, link) do
    quote do
      <<unquote(glyph)::binary-size(12), unquote(fg)::32-little, unquote(bg)::32-little,
        unquote(ul)::32-little, unquote(attrs)::16-little, unquote(width)::8, 0::8,
        unquote(link)::32-little>>
    end
  end

  @doc "True when the raw glyph bytes are an overflow ref."
  defguard overflow?(glyph) when binary_part(glyph, 0, 1) == <<@overflow>>

  @doc "Number of columns in a row."
  @spec cols(row) :: non_neg_integer
  def cols(row), do: div(byte_size(row) - 4 - trailer_len(row), @size)

  @doc "The records of a row, without trailer or footer."
  @spec records(row) :: binary
  def records(row), do: binary_part(row, 0, byte_size(row) - 4 - trailer_len(row))

  @doc "True when the row carries no overflow clusters."
  @spec plain?(row) :: boolean
  def plain?(row), do: trailer_len(row) == 0

  defp trailer_len(row),
    do: :binary.decode_unsigned(binary_part(row, byte_size(row), -4), :little)

  defp trailer(row) do
    len = trailer_len(row)
    binary_part(row, byte_size(row) - 4 - len, len)
  end

  @doc "A row of `cols` empty default cells."
  @spec blank_row(non_neg_integer) :: row
  def blank_row(cols),
    do: :binary.copy(encode_record(%__MODULE__{}, 0) |> elem(0), cols) <> <<0::32>>

  @doc "Encodes cells into a packed row."
  @spec encode_row([t]) :: row
  def encode_row(cells) do
    {records, trailer, _} =
      Enum.reduce(cells, {[], [], 0}, fn cell, {recs, tr, off} ->
        {rec, extra} = encode_record(cell, off)
        {[recs, rec], [tr, extra], off + byte_size(extra)}
      end)

    trailer = IO.iodata_to_binary(trailer)
    IO.iodata_to_binary([records, trailer, <<byte_size(trailer)::32-little>>])
  end

  defp encode_record(%__MODULE__{} = c, off) do
    {glyph, extra} =
      if byte_size(c.glyph) <= @glyph_bytes do
        {c.glyph <> :binary.copy(<<0>>, @glyph_bytes - byte_size(c.glyph)), ""}
      else
        {<<@overflow, 0::24, off::32-little, byte_size(c.glyph)::32-little>>, c.glyph}
      end

    rec =
      record(
        glyph,
        enc_color(c.fg),
        enc_color(c.bg),
        enc_color(c.ul),
        enc_attrs(c),
        c.width,
        c.link
      )

    {rec, extra}
  end

  defp enc_color(:default), do: 0
  defp enc_color({:palette, i}), do: 1 <<< 24 ||| i
  defp enc_color({:rgb, r, g, b}), do: 2 <<< 24 ||| r <<< 16 ||| g <<< 8 ||| b

  defp enc_attrs(c) do
    flags =
      @flags
      |> Enum.with_index()
      |> Enum.reduce(0, fn {f, i}, acc -> if f in c.attrs, do: acc ||| 1 <<< i, else: acc end)

    flags ||| Enum.find_index(@underlines, &(&1 == c.underline)) <<< 8
  end

  @doc "Decodes a packed row into cells, resolving overflow clusters."
  @spec decode_row(row) :: [t]
  def decode_row(row) do
    tr = trailer(row)
    for <<rec::binary-size(@size) <- records(row)>>, do: decode_record(rec, tr)
  end

  defp decode_record(record(glyph, fg, bg, ul, attrs, width, link), tr) do
    %__MODULE__{
      glyph: dec_glyph(glyph, tr),
      fg: dec_color(fg),
      bg: dec_color(bg),
      ul: dec_color(ul),
      attrs: for({f, i} <- Enum.with_index(@flags), (attrs &&& 1 <<< i) != 0, do: f),
      underline: Enum.at(@underlines, attrs >>> 8 &&& 0x7, :single),
      width: width,
      link: link
    }
  end

  defp dec_glyph(<<@overflow, _::24, off::32-little, len::32-little>>, tr),
    do: binary_part(tr, off, len)

  defp dec_glyph(glyph, _tr), do: hd(:binary.split(glyph, <<0>>))

  defp dec_color(v) do
    case v >>> 24 do
      0 -> :default
      1 -> {:palette, v &&& 0xFF}
      2 -> {:rgb, v >>> 16 &&& 0xFF, v >>> 8 &&& 0xFF, v &&& 0xFF}
    end
  end

  @doc "Columns `x..x+w-1` of a row as a new row."
  @spec slice(row, non_neg_integer, non_neg_integer) :: row
  def slice(row, x, w) do
    if plain?(row) do
      binary_part(row, x * @size, w * @size) <> <<0::32>>
    else
      row |> decode_row() |> Enum.slice(x, w) |> encode_row()
    end
  end

  @doc "Concatenates rows left to right into one row."
  @spec concat([row]) :: row
  def concat(rows) do
    if Enum.all?(rows, &plain?/1) do
      IO.iodata_to_binary([Enum.map(rows, &records/1), <<0::32>>])
    else
      rows |> Enum.flat_map(&decode_row/1) |> encode_row()
    end
  end
end
