defmodule DynideTerm.Demo.FakeRowsTest do
  use ExUnit.Case, async: true

  alias DynideScene.Cell
  alias DynideTerm.Demo.FakeRows

  defp text(row), do: row |> Cell.decode_row() |> Enum.map_join(& &1.glyph)

  test "frame has one row per line, each exactly cols wide, with the header first" do
    rows = FakeRows.frame(40, 10, %{tick: 7, last_input: "x", pid: "123"})

    assert Enum.map(rows, &elem(&1, 0)) == Enum.to_list(0..9)
    assert Enum.all?(rows, fn {_, row} -> Cell.cols(row) == 40 end)
    [{0, row0} | _] = rows
    assert text(row0) =~ ~r/^herdr-live demo 40x10 pid 123/
    assert Enum.any?(rows, fn {_, row} -> text(row) =~ "last input: 78" end)
  end

  test "tiny and narrow sizes stay exactly cols wide without splitting wide cells" do
    for cols <- 1..12, rows <- 1..8 do
      frame = FakeRows.frame(cols, rows, %{tick: 0, last_input: "", pid: "1"})
      assert length(frame) == rows

      for {_, row} <- frame do
        cells = Cell.decode_row(row)
        assert length(cells) == cols
        widths = Enum.map(cells, & &1.width)
        refute List.last(widths) == 2 or hd(widths) == 0
        assert widths |> Enum.chunk_every(2, 1) |> Enum.all?(&(&1 != [1, 0] and &1 != [0, 0]))
      end
    end
  end
end
