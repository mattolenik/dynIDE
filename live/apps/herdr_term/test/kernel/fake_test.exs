defmodule HerdrTerm.Kernel.FakeTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Cells
  alias HerdrTerm.Kernel.Fake.{Blit, Tty}

  @s Cells.style([])
  @opts %{cursor: nil, shape: :block, repaint: false}

  test "inject, size, write" do
    {:ok, tty} = Tty.open()
    assert Tty.size(tty) == {80, 24, 0, 0}
    :ok = Tty.subscribe(tty, self())
    Tty.inject(tty, "x")
    assert_receive {:tty_input, "x"}
    Tty.write(tty, ["a", "b"])
    Tty.write(tty, "c")
    assert Tty.written(tty) == "abc"
    Tty.set_size(tty, {10, 5, 1, 2})
    assert Tty.size(tty) == {10, 5, 1, 2}
    assert :ok = Tty.suspend(tty)
    assert :ok = Tty.restore(tty)
    {:ok, t2} = Tty.open(size: {1, 2, 3, 4})
    assert Tty.size(t2) == {1, 2, 3, 4}
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
  end

  test "frame log is bounded" do
    {:ok, tty} = Tty.open()
    for _ <- 1..1005, do: Blit.frame(tty, [], @opts)
    assert length(Blit.frames(tty)) == 1000
  end
end
