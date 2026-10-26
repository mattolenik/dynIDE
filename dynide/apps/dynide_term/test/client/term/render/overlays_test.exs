defmodule DynideTerm.Client.Term.Render.OverlaysTest do
  use ExUnit.Case, async: true

  alias DynideScene.Cell
  alias DynideScene.Scene.Overlay
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Overlays
  alias DynideTerm.Client.Term.Theme

  @s Cells.style([])
  @theme Theme.default()
  @ctx %{w: 10, h: 10, focused: true}

  defp row, do: Cells.text("abcdefghij", @s)
  defp cells(row), do: Cell.decode_row(row)
  defp ov(kind, args), do: %Overlay{kind: kind, args: args}
  defp sel, do: ov(:selection, %{from: {2, 0}, to: {4, 0}})

  test "no overlays or untouched rows return the row unchanged" do
    r = row()
    assert Overlays.apply(r, [], 0, @ctx, @theme) == r
    assert Overlays.apply(r, [sel()], 1, @ctx, @theme) == r
  end

  test "selection is inverse when the host background is unknown" do
    cs = cells(Overlays.apply(row(), [sel()], 0, @ctx, @theme))

    assert for(c <- cs, do: :inverse in c.attrs) ==
             List.duplicate(false, 2) ++
               List.duplicate(true, 3) ++ List.duplicate(false, 5)
  end

  test "selection mixes a dark host bg 28% toward white with contrasting fg" do
    theme = %{@theme | host: %{fg: nil, bg: {0, 0, 0}}}
    c = Enum.at(cells(Overlays.apply(row(), [sel()], 0, @ctx, theme)), 3)
    assert c.bg == {:rgb, 71, 71, 71}
    assert c.fg == {:rgb, 255, 255, 255}
    assert c.attrs == []
    assert c.glyph == "d"
  end

  test "selection mixes a light host bg toward black" do
    theme = %{@theme | host: %{fg: nil, bg: {255, 255, 255}}}
    c = Enum.at(cells(Overlays.apply(row(), [sel()], 0, @ctx, theme)), 2)
    assert c.bg == {:rgb, 184, 184, 184}
    assert c.fg == {:rgb, 0, 0, 0}
  end

  test "multi-row stream selection: middle rows full width, swapped ends" do
    o = ov(:selection, %{from: {3, 2}, to: {7, 0}})

    inv = fn y ->
      for c <- cells(Overlays.apply(row(), [o], y, @ctx, @theme)), do: :inverse in c.attrs
    end

    assert inv.(0) == List.duplicate(false, 7) ++ List.duplicate(true, 3)
    assert inv.(1) == List.duplicate(true, 10)
    assert inv.(2) == List.duplicate(true, 4) ++ List.duplicate(false, 6)
  end

  test "link hover and search match underline; current match and copy cursor are accent" do
    hover = ov(:link_hover, %{id: 0, from: {0, 0}, to: {1, 0}})
    match = ov(:search_match, %{from: {3, 0}, to: {4, 0}, current: false})
    cur = ov(:search_match, %{from: {6, 0}, to: {6, 0}, current: true})
    cc = ov(:copy_cursor, %{at: {8, 0}})
    cs = cells(Overlays.apply(row(), [hover, match, cur, cc], 0, @ctx, @theme))

    assert Enum.map(cs, & &1.underline) ==
             [:single, :single, :none, :single, :single, :none, :none, :none, :none, :none]

    for i <- [6, 8] do
      c = Enum.at(cs, i)
      assert c.fg == {:palette, 4}
      assert Enum.sort(c.attrs) == [:bold, :inverse]
    end

    assert Enum.at(cs, 7).attrs == []
    assert cells(Overlays.apply(row(), [cc], 1, @ctx, @theme)) == cells(row())
  end

  test "dim fades the whole row" do
    cs = cells(Overlays.apply(row(), [ov(:dim, %{reason: :inactive})], 4, @ctx, @theme))
    assert Enum.all?(cs, &(:faint in &1.attrs))
  end

  defp bar(offset, focused) do
    o = ov(:scrollbar, %{total: 100, viewport: 10, offset: offset})
    ctx = %{@ctx | focused: focused}

    for y <- 0..9 do
      c = row() |> then(&Overlays.apply(&1, [o], y, ctx, @theme)) |> cells() |> List.last()
      {c.glyph, :faint in c.attrs}
    end
  end

  test "scrollbar thumb at the top and bottom of a 10-row track (total 100, viewport 10)" do
    track = {"▕", true}
    assert bar(0, true) == [{"▐", false} | List.duplicate(track, 9)]
    assert bar(90, true) == List.duplicate(track, 9) ++ [{"▐", false}]
    assert bar(90, false) == List.duplicate(track, 9) ++ [{"▕", false}]
  end

  test "an offset past the end keeps the thumb on the track" do
    assert bar(500, true) == List.duplicate({"▕", true}, 9) ++ [{"▐", false}]
  end

  test "scrollbar replaces column w-1 only, keeping the width when a wide char straddles it" do
    o = ov(:scrollbar, %{total: 100, viewport: 10, offset: 0})
    r = Cells.text("abcdefgh日", @s)
    out = Overlays.apply(r, [o], 0, @ctx, @theme)
    assert Cell.cols(out) == 10
    assert Cells.to_text(out) == "abcdefgh ▐"
  end

  test "thumb length follows viewport/total, clamped to the track" do
    o = ov(:scrollbar, %{total: 20, viewport: 10, offset: 5})

    glyphs =
      for y <- 0..9,
          do:
            row()
            |> then(&Overlays.apply(&1, [o], y, @ctx, @theme))
            |> cells()
            |> List.last()
            |> Map.fetch!(:glyph)

    # len round(10*10/20) = 5, top round(5*5/10) = 3 (round half away from zero)
    assert glyphs == List.duplicate("▕", 3) ++ List.duplicate("▐", 5) ++ List.duplicate("▕", 2)
  end
end
