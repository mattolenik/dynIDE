defmodule HerdrServer.Native.VtTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Cell
  alias HerdrServer.Native.Vt

  defp text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&glyph/1) |> String.trim_trailing()

  defp glyph(%Cell{glyph: ""}), do: " "
  defp glyph(%Cell{glyph: g}), do: g

  setup do
    {:ok, vt} = Vt.new(80, 24, 1000)
    %{vt: vt}
  end

  test "feed then full_rows decodes the text", %{vt: vt} do
    gen = Vt.feed(vt, "hi")
    assert {^gen, rows} = Vt.full_rows(vt)
    assert length(rows) == 24
    assert {0, row0} = hd(rows)
    assert text(row0) == "hi"
    assert Enum.all?(rows, fn {_, row} -> Cell.cols(row) == 80 end)
  end

  test "dirty_rows returns only changed rows", %{vt: vt} do
    {_, all} = Vt.dirty_rows(vt)
    assert length(all) == 24
    assert {_, []} = Vt.dirty_rows(vt)
    gen = Vt.feed(vt, "\e[3;1Hx")
    assert {^gen, [{2, _}]} = Vt.dirty_rows(vt)
    assert {_, [{2, _}]} = Vt.rows_since(vt, gen - 1)
  end

  test "modes", %{vt: vt} do
    assert Vt.mode(vt, :bracketed_paste) == false
    Vt.feed(vt, "\e[?2004h")
    assert Vt.mode(vt, :bracketed_paste) == true
    assert Vt.mode(vt, :alt_screen) == false
    assert Vt.kitty_keyboard_flags(vt) == 0
  end

  test "unknown mode raises", %{vt: vt} do
    assert_raise ArgumentError, fn -> Vt.mode(vt, :nope) end
  end

  test "encode_key", %{vt: vt} do
    assert Vt.encode_key(vt, %{key: :up, mods: [], event: :press, text: nil}) == "\e[A"
    assert Vt.encode_key(vt, %{key: "a", mods: [], event: :press, text: "a"}) == "a"
    assert Vt.encode_key(vt, %{key: "c", mods: [:ctrl], event: :press, text: nil}) == <<3>>

    assert_raise ArgumentError, fn ->
      Vt.encode_key(vt, %{key: :nope, mods: [], event: :press, text: nil})
    end
  end

  test "encode_mouse and encode_focus", %{vt: vt} do
    ev = %{kind: :press, button: :left, x: 0, y: 0, mods: [], px: nil}
    assert Vt.encode_mouse(vt, ev) == nil
    assert Vt.encode_focus(vt, true) == ""
    Vt.feed(vt, "\e[?1000h\e[?1006h\e[?1004h")
    assert Vt.encode_mouse(vt, ev) == "\e[<0;1;1M"
    assert Vt.encode_focus(vt, true) == "\e[I"
    assert_raise ArgumentError, fn -> Vt.encode_mouse(vt, %{ev | kind: :bogus}) end
  end

  test "resize, scrollbar, scroll_to, cursor, read_text", %{vt: vt} do
    assert Vt.resize(vt, 40, 10, {8, 16}) == :ok
    {_, rows} = Vt.full_rows(vt)
    assert length(rows) == 10
    Enum.each(0..19, fn i -> Vt.feed(vt, "line#{i}\r\n") end)
    assert %{total: total, viewport: 10, offset: offset} = Vt.scrollbar(vt)
    assert offset == total - 10
    assert %{x: 0, y: 9, visible: true, blinking: _, shape: :block} = Vt.cursor(vt)
    assert Vt.scroll_to(vt, 0) == :ok
    assert %{offset: 0} = Vt.scrollbar(vt)
    assert Vt.cursor(vt) == nil
    assert Vt.read_text(vt, :screen) =~ "line19"
    assert Vt.read_text(vt, {:rows, 0..0}) |> String.trim_trailing() == "line0"
    assert is_binary(Vt.read_text(vt, :viewport))
  end

  test "link_at and graphics_placements", %{vt: vt} do
    Vt.feed(vt, "\e]8;;https://example.com\e\\ab\e]8;;\e\\")
    assert Vt.link_at(vt, 0, 0) == %{uri: "https://example.com", kind: :hyperlink}
    assert Vt.link_at(vt, 70, 20) == nil
    assert Vt.graphics_placements(vt) == []
  end
end
