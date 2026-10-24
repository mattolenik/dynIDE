defmodule HerdrTerm.CellsTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Cell
  alias HerdrTerm.Cells

  @s Cells.style([])
  @family "👩‍👩‍👧‍👦"

  test "text round-trips and counts columns" do
    row = Cells.text("héllo", @s)
    assert Cell.cols(row) == 5
    assert Cells.to_text(row) == "héllo"
    assert Cell.cols(Cells.text("日本", @s)) == 4
  end

  test "repeat and blank match per-cell encoding" do
    s = Cells.style(fg: {:palette, 4}, attrs: [:bold])

    for g <- ["─", "x", "日", @family], n <- [0, 1, 7] do
      assert Cells.repeat(g, n, s) == Cells.text(String.duplicate(g, n), s)
    end

    for n <- [0, 1, 7],
        do: assert(Cells.blank(n, s) == Cell.encode_row(List.duplicate(%{s | width: 1}, n)))
  end

  test "style builds a template" do
    s = Cells.style(fg: {:palette, 1}, bg: {:rgb, 1, 2, 3}, attrs: [:bold], underline: :curly)
    assert %Cell{glyph: "", fg: {:palette, 1}, bg: {:rgb, 1, 2, 3}, attrs: [:bold]} = s
    assert s.underline == :curly and s.link == 0
  end

  test "fit never splits wide chars" do
    row = Cells.text("ab日c", @s)
    assert Cells.to_text(Cells.fit(row, 3, 1)) == " "
    assert Cells.to_text(Cells.fit(row, 2, 1)) == " "
    assert Cells.to_text(Cells.fit(row, 2, 2)) == "日"
    assert Cells.to_text(Cells.fit(row, 1, 3)) == "b日"
    assert Cells.to_text(Cells.fit(Cells.text("ab", @s), 1, 4)) == "b   "
    assert Cell.cols(Cells.fit(Cells.text("ab", @s), 5, 3)) == 3
  end

  test "fit cuts a head at the right edge" do
    assert Cells.to_text(Cells.fit(Cells.text("ab日c", @s), 1, 2)) == "b "
  end

  test "restyle touches only the range" do
    cells =
      Cells.restyle(Cells.text("abcd", @s), 1, 2, add_attrs: [:inverse]) |> Cell.decode_row()

    assert Enum.map(cells, &(:inverse in &1.attrs)) == [false, true, true, false]

    [_, c | _] =
      Cells.restyle(Cells.text("abcd", @s), 1, 1,
        fg: {:palette, 2},
        bg: {:palette, 3},
        underline: :single
      )
      |> Cell.decode_row()

    assert {c.fg, c.bg, c.underline} == {{:palette, 2}, {:palette, 3}, :single}
  end

  test "overflow clusters survive fit/concat/restyle" do
    row = Cells.text("a" <> @family <> "b", @s)
    refute Cell.plain?(row)
    assert Cells.to_text(Cells.fit(row, 0, 4)) == "a" <> @family <> "b"
    assert Cells.to_text(Cells.fit(row, 1, 3)) == @family <> "b"
    joined = Cells.concat([row, Cells.blank(2, @s), row])
    assert Cells.to_text(joined) == "a#{@family}b  a#{@family}b"
    r = Cells.restyle(row, 0, 2, add_attrs: [:bold])
    assert Cells.to_text(r) == Cells.to_text(row)
    refute Cell.plain?(r)
  end
end
