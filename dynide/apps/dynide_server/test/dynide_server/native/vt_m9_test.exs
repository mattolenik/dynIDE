defmodule DynideServer.Native.VtM9Test do
  use ExUnit.Case, async: false

  alias DynideScene.Cell
  alias DynideServer.Native.{Pty, Vt}

  # The child reads `n` reply bytes from the pty and prints them with ESC shown as "E".
  defp reply_to(vt, id, query, n) do
    script = "stty raw -echo; printf '#{query}'; head -c #{n} | tr '\\033' E; sleep 5"
    {:ok, pty, _} = Pty.spawn(vt, id, "/bin/sh", ["-c", script], [], nil, 80, 24)
    on_exit(fn -> Pty.kill(pty, :kill) end)
    poll_text(vt, System.monotonic_time(:millisecond) + 3000)
  end

  defp poll_text(vt, deadline) do
    text = vt |> Vt.read_text(:viewport) |> String.trim()

    if text == "" and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      poll_text(vt, deadline)
    else
      # let the rest of a partial line land
      Process.sleep(50)
      vt |> Vt.read_text(:viewport) |> String.trim()
    end
  end

  defp text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))

  test "set_colors: ghostty answers OSC 10 with the default fg" do
    {:ok, vt} = Vt.new(80, 24, 1000)
    assert :ok = Vt.set_colors(vt, %{fg: {1, 2, 3}, bg: nil, cursor: nil, palette: %{}})
    assert reply_to(vt, 9101, "\\033]10;?\\033\\\\", 25) == "E]10;rgb:0101/0202/0303E\\"
  end

  test "set_colors: an unset bg gets no OSC 11 reply, DA1 comes first" do
    {:ok, vt} = Vt.new(80, 24, 1000)
    assert :ok = Vt.set_colors(vt, %{fg: {1, 2, 3}})
    assert reply_to(vt, 9102, "\\033]11;?\\033\\\\\\033[c", 9) == "E[?62;22c"
  end

  test "set_colors: palette entries overlay the default palette" do
    {:ok, vt} = Vt.new(80, 24, 1000)
    assert :ok = Vt.set_colors(vt, %{palette: %{1 => {255, 0, 0}}})
    assert reply_to(vt, 9103, "\\033]4;1;?\\033\\\\", 26) == "E]4;1;rgb:ffff/0000/0000E\\"
  end

  test "set_color_scheme: ghostty answers CSI ? 996 n" do
    {:ok, vt} = Vt.new(80, 24, 1000)
    assert :ok = Vt.set_color_scheme(vt, :dark)
    assert reply_to(vt, 9104, "\\033[?996n", 9) == "E[?997;1n"
  end

  test "set_colors and set_color_scheme reject bad input" do
    {:ok, vt} = Vt.new(80, 24, 1000)
    assert_raise ArgumentError, fn -> Vt.set_colors(vt, %{fg: {300, 0, 0}}) end
    assert_raise ArgumentError, fn -> Vt.set_colors(vt, %{palette: %{256 => {0, 0, 0}}}) end
    assert :ok = Vt.set_color_scheme(vt, nil)
  end

  test "read_text selection joins soft wraps, orders and clamps points" do
    {:ok, vt} = Vt.new(20, 5, 1000)
    Vt.feed(vt, "abcdefghijklmnopqrstuvwxy\r\nnext  ")
    assert Vt.read_text(vt, {:selection, {0, 0}, {19, 1}}) == "abcdefghijklmnopqrstuvwxy"
    assert Vt.read_text(vt, {:selection, {4, 0}, {2, 0}}) == "cde"
    assert Vt.read_text(vt, {:selection, {999, 999}, {0, 2}}) == "next"
  end

  test "screen_rows: glyph and width only, wrapped flag, rows past the end omitted" do
    {:ok, vt} = Vt.new(20, 5, 1000)
    Vt.feed(vt, "\e[31mab世\e[0m\r\n")
    Vt.feed(vt, "abcdefghijklmnopqrstuvwxy")
    rows = Vt.screen_rows(vt, 0, 100)
    assert Enum.map(rows, &elem(&1, 0)) == [0, 1, 2, 3, 4]
    [{0, r0, false}, {1, _, true}, {2, r2, false} | _] = rows
    cells = Cell.decode_row(r0)
    assert Enum.take(Enum.map(cells, & &1.width), 5) == [1, 1, 2, 0, 1]
    assert Enum.at(cells, 2).glyph == "世"
    assert Enum.all?(cells, &(&1 == %Cell{glyph: &1.glyph, width: &1.width}))
    assert String.trim_trailing(text(r2)) == "uvwxy"
    assert Vt.screen_rows(vt, 50, 60) == []
  end

  test "modify_other_keys follows CSI > 4 ; 2 m" do
    {:ok, vt} = Vt.new(20, 5, 1000)
    assert Vt.modify_other_keys(vt) == false
    Vt.feed(vt, "\e[>4;2m")
    assert Vt.modify_other_keys(vt) == true
  end

  test "a fresh vt's cursor style (Task 3's :default)" do
    {:ok, vt} = Vt.new(20, 5, 1000)
    assert %{shape: :block, blinking: false} = Vt.cursor(vt)
  end

  # Pane.Server re-reads :alt_screen on damage with dirty rows: a screen switch dirties
  # some rows (only the cursor row here, so "every row dirty" would miss it)
  test "switching to and from the alt screen dirties rows and flips the mode" do
    {:ok, vt} = Vt.new(80, 24, 100)
    Vt.feed(vt, "hello\r\n")
    Vt.dirty_rows(vt)

    Vt.feed(vt, "\e[?1049h")
    assert {_, [_ | _]} = Vt.dirty_rows(vt)
    assert Vt.mode(vt, :alt_screen) == true

    Vt.feed(vt, "\e[?1049l")
    assert {_, [_ | _]} = Vt.dirty_rows(vt)
    assert Vt.mode(vt, :alt_screen) == false
  end
end
