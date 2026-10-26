defmodule DynideTerm.Kernel.FakeTest do
  use ExUnit.Case, async: true

  alias DynideTerm.Cells
  alias DynideTerm.Kernel.Fake.{Blit, Tty}

  @s Cells.style([])
  @opts %{cursor: nil, shape: :block, repaint: false}

  test "inject, size, write, stats, kitty, suspend, hangup" do
    {:ok, tty} = Tty.open(%{path: "/dev/tty", kitty_flags: 1})
    assert Tty.size(tty) == {80, 24, 0, 0}
    assert Tty.kitty_keyboard(tty) == nil
    :ok = Tty.subscribe(tty, self())
    Tty.inject(tty, "x")
    assert_receive {:tty_input, "x"}
    Tty.write(tty, ["a", "b"])
    Tty.write(tty, "c")
    assert Tty.written(tty) == "abc"
    Tty.set_size(tty, {10, 5, 1, 2})
    assert Tty.size(tty) == {10, 5, 1, 2}
    assert :ok = Tty.suspend(tty)
    assert_receive {:tty_resumed}
    Tty.hangup(tty)
    assert_receive {:exit, :tty, :hangup}
    assert :ok = Tty.restore(tty)
    assert %{frames_written: 0, frames_dropped: 0, queued_bytes: 0} = Tty.stats(tty)
    {:ok, t2} = Tty.open(%{size: {1, 2, 3, 4}, kitty: 0})
    assert Tty.size(t2) == {1, 2, 3, 4}
    assert Tty.kitty_keyboard(t2) == 0
    assert Tty.open(%{error: :enxio}) == {:error, :enxio}
  end

  test "frames apply to the retained screen" do
    {:ok, tty} = Tty.open()
    Blit.subscribe_frames(tty, self())
    :ok = Blit.frame(tty, [{0, Cells.text("hi", @s)}, {1, Cells.text("yo", @s)}], @opts)
    assert_receive {:frame, ^tty, %{rows: [0, 1], repaint: false}}
    assert ["hi" <> _, "yo" <> _ | _] = Blit.screen(tty)
    :ok = Blit.frame(tty, [{0, Cells.text("zz", @s)}], %{@opts | repaint: true, cursor: {1, 0}})
    assert ["zz" <> _, "" | _] = Blit.screen(tty)

    assert [%{rows: [0, 1]}, %{rows: [0], repaint: true, cursor: {1, 0}, at: at}] =
             Blit.frames(tty)

    assert is_integer(at)
    assert Tty.stats(tty).frames_written == 2
  end

  test "bad frames are refused like the real blitter, and not recorded" do
    {:ok, tty} = Tty.open()
    row = Cells.text("ab", @s)

    for {rows, opts} <- [
          {[], @opts},
          {[{1, row}], @opts},
          {[{0, row}, {2, row}], @opts},
          {[{0, row}, {1, Cells.text("abc", @s)}], @opts},
          {[{0, Cells.text("", @s)}], @opts},
          {[{0, row}], %{@opts | shape: :beam}}
        ] do
      assert Blit.frame(tty, rows, opts) == {:error, :bad_frame}, inspect({rows, opts})
    end

    assert Blit.frames(tty) == []
  end

  test "graphics ops are recorded as given; a malformed op is refused" do
    {:ok, tty} = Tty.open()
    rows = [{0, Cells.text("ab", @s)}]
    ops = [{:delete_image, 7}, :delete_all]
    :ok = Blit.frame(tty, rows, Map.put(@opts, :graphics, ops))
    :ok = Blit.frame(tty, rows, @opts)
    assert [%{graphics: ^ops}, %{graphics: []}] = Blit.frames(tty)
    assert Blit.frame(tty, rows, Map.put(@opts, :graphics, [{:nope}])) == {:error, :bad_frame}
    assert %{graphics_bytes: 0, file_transport: :unknown} = Tty.stats(tty)
  end

  test "frame log is bounded" do
    {:ok, tty} = Tty.open()
    row = [{0, Cells.text("x", @s)}]
    for _ <- 1..1005, do: Blit.frame(tty, row, @opts)
    assert length(Blit.frames(tty)) == 1000
    assert Tty.stats(tty).frames_written == 1005
  end
end
