defmodule DynideScene.CellTest do
  use ExUnit.Case, async: true

  alias DynideScene.Cell
  require Cell

  @path Path.expand("../support/packed_cell_vectors.json", __DIR__)
  @external_resource @path
  @vectors @path |> File.read!() |> JSON.decode!()

  defp to_cell(m) do
    %Cell{
      glyph: m["glyph"],
      fg: color(m["fg"]),
      bg: color(m["bg"]),
      ul: color(m["ul"]),
      attrs: Enum.map(m["attrs"], &String.to_existing_atom/1),
      underline: String.to_existing_atom(m["underline"]),
      width: m["width"],
      link: m["link"]
    }
  end

  defp color("default"), do: :default
  defp color(%{"palette" => i}), do: {:palette, i}
  defp color(%{"rgb" => [r, g, b]}), do: {:rgb, r, g, b}

  test "record size matches the vectors" do
    assert @vectors["record_size"] == Cell.size()
  end

  for v <- @vectors["vectors"] do
    @v v
    test "golden vector #{v["name"]}" do
      cells = Enum.map(@v["cells"], &to_cell/1)
      bin = Base.decode16!(@v["hex"], case: :lower)
      assert Cell.encode_row(cells) == bin
      assert Cell.decode_row(bin) == cells
      assert Cell.cols(bin) == length(cells)
      assert byte_size(Cell.records(bin)) == length(cells) * Cell.size()
    end
  end

  defp vector(name), do: Enum.find(@vectors["vectors"], &(&1["name"] == name))
  defp row(name), do: Base.decode16!(vector(name)["hex"], case: :lower)
  defp cells(name), do: Enum.map(vector(name)["cells"], &to_cell/1)

  test "record/7 matches and builds raw records" do
    <<Cell.record(glyph, fg, _bg, _ul, attrs, width, link), _::binary>> = row("link_ids")
    assert {glyph, fg, attrs, width, link} == {"h" <> <<0::88>>, 0, 0, 1, 1}
    glyph = "h" <> <<0::88>>
    assert Cell.record(glyph, 0, 0, 0, 0, 1, 1) == binary_part(row("link_ids"), 0, 32)
  end

  test "overflow? guard" do
    <<Cell.record(glyph, _, _, _, _, _, _), _::binary>> = row("combining_overflow")
    assert Cell.overflow?(glyph)
    refute Cell.overflow?("a" <> <<0::88>>)
  end

  test "blank_row is cols default empty cells" do
    assert Cell.decode_row(Cell.blank_row(3)) == List.duplicate(%Cell{}, 3)
    assert Cell.plain?(Cell.blank_row(3))
  end

  test "slice and concat preserve cells, including overflow" do
    for name <- ["ascii_padded", "emoji_zwj_overflow_twice", "wide_cjk"] do
      r = row(name)
      cs = cells(name)
      n = length(cs)
      assert Cell.concat([Cell.slice(r, 0, 2), Cell.slice(r, 2, n - 2)]) == r
      assert Cell.decode_row(Cell.slice(r, 1, n - 1)) == Enum.drop(cs, 1)
    end

    mixed =
      Cell.concat([
        row("emoji_zwj_overflow_twice"),
        row("combining_overflow"),
        row("ascii_padded")
      ])

    assert Cell.decode_row(mixed) ==
             cells("emoji_zwj_overflow_twice") ++
               cells("combining_overflow") ++ cells("ascii_padded")
  end
end
