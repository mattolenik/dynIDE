defmodule HerdrServer.Kernel.FakeTest do
  use ExUnit.Case, async: false

  alias HerdrScene.{Cell, Event}
  alias HerdrServer.Kernel
  alias HerdrServer.Kernel.Fake.{Keeper, Pty, Vt}

  @opts %{cmd: "sh", args: [], env: [], cwd: "/", cols: 20, rows: 5}

  setup do
    on_exit(fn -> Enum.each(Keeper.pane_ids(), &Keeper.close/1) end)
    {:ok, %{vt: vt, pty: pty}} = Keeper.open(1, @opts)
    :ok = Pty.subscribe(pty, self())
    assert_receive {:damage, 1, _}
    # drain the forced full damage
    Vt.dirty_rows(vt)
    {:ok, vt: vt, pty: pty}
  end

  defp text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))

  test "kernel modules resolve to the fake in test" do
    assert Kernel.vt() == Vt
    assert Kernel.pty() == Pty
    assert Kernel.keeper() == Keeper
  end

  test "write echoes, damage once, dirty rows consumed", %{vt: vt, pty: pty} do
    :ok = Pty.write(pty, "hi")
    assert_receive {:damage, 1, gen}, 50
    assert {^gen, [{0, row}]} = Vt.dirty_rows(vt)
    assert String.starts_with?(text(row), "hi")
    assert {^gen, []} = Vt.dirty_rows(vt)
  end

  test "resubscribe forces full damage", %{vt: vt, pty: pty} do
    :ok = Pty.subscribe(pty, self())
    assert_receive {:damage, 1, _}
    assert {_, rows} = Vt.dirty_rows(vt)
    assert Enum.map(rows, &elem(&1, 0)) == [0, 1, 2, 3, 4]
  end

  test "output interprets CR LF, cursor, clear, home", %{vt: vt, pty: pty} do
    Pty.output(pty, "a\r\nb")
    assert_receive {:damage, 1, _}, 50
    assert %{x: 1, y: 1} = Vt.cursor(vt)
    assert Vt.read_text(vt, :viewport) == "a\nb\n\n\n"
    Pty.output(pty, "\e[2;5Hz\e[Hq\e[31m!\e[2J")
    assert_receive {:damage, 1, _}, 50
    assert Vt.read_text(vt, :screen) == "\n\n\n\n"
    Pty.output(pty, "\e[Hab\b\bx\ty")
    assert_receive {:damage, 1, _}, 50
    assert Vt.read_text(vt, {:rows, 0..0}) == "xb      y"
  end

  test "scrolls at the bottom", %{vt: vt, pty: pty} do
    Pty.output(pty, "1\n2\n3\n4\n5\n6")
    assert_receive {:damage, 1, _}, 50

    assert Vt.read_text(vt, :viewport) |> String.split("\n") |> Enum.map(&String.trim/1) == [
             "2",
             "3",
             "4",
             "5",
             "6"
           ]
  end

  test "floods are coalesced and the last state is visible", %{vt: vt, pty: pty} do
    for i <- 1..10_000, do: Pty.output(pty, "x#{rem(i, 10)}\r")
    Pty.output(pty, "\e[Hdone")
    Process.sleep(50)
    assert Vt.read_text(vt, {:rows, 0..0}) |> String.starts_with?("done")
    assert length(flush()) < 10_000 / 10
  end

  test "a large chunk interprets only the visible tail", %{vt: vt, pty: pty} do
    Pty.output(pty, String.duplicate("é", 1_000_000) <> "\r\nend")
    assert_receive {:damage, 1, _}, 500
    assert Vt.read_text(vt, :viewport) |> String.contains?("end")
    assert {_, [_ | _]} = Vt.dirty_rows(vt)
  end

  test "hidden suppresses damage but rows update", %{vt: vt, pty: pty} do
    :ok = Pty.set_hidden(pty, true)
    Pty.output(pty, "q")
    refute_receive {:damage, _, _}, 20
    assert Vt.read_text(vt, {:rows, 0..0}) |> String.starts_with?("q")
    :ok = Pty.set_hidden(pty, false)
    assert_receive {:damage, 1, _}
  end

  test "kill notifies subscribers with the pane id", %{pty: pty} do
    :ok = Pty.kill(pty, :sigterm)
    assert_receive {:exit, 1, {:signal, :sigterm}}
  end

  test "resize keeps content", %{vt: vt, pty: pty} do
    Pty.output(pty, "hey")
    :ok = Pty.resize(pty, 10, 3, nil)
    assert Vt.read_text(vt, :viewport) == "hey\n\n"
    assert {_, [_, _, _]} = Vt.dirty_rows(vt)
  end

  test "encode_key", %{vt: vt} do
    assert Vt.encode_key(vt, Event.key("a")) == "a"
    assert Vt.encode_key(vt, Event.key("c", [:ctrl])) == <<3>>
    assert Vt.encode_key(vt, Event.key("x", [:alt])) == "\ex"
    assert Vt.encode_key(vt, Event.key(:up, [:shift])) == "\e[1;2A"
    assert Vt.encode_key(vt, Event.key(:up)) == "\e[A"
    assert Vt.encode_key(vt, Event.key(:enter)) == "\r"
    assert Vt.encode_key(vt, Event.key(:backspace)) == "\x7f"
    assert Vt.encode_key(vt, Event.key(:page_up)) == "\e[5~"
    assert Vt.encode_key(vt, Event.key(:f1)) == "\eOP"
    assert Vt.encode_key(vt, Event.key(:f5, [:ctrl])) == "\e[15;5~"
    assert Vt.encode_key(vt, Event.key("a", [], event: :release)) == ""
    Vt.set_kitty_flags(vt, 1)
    assert Vt.kitty_keyboard_flags(vt) == 1
    assert Vt.encode_key(vt, Event.key("a", [:ctrl])) == "\e[97;5u"
    assert Vt.encode_key(vt, Event.key(:enter, [:shift])) == "\e[13;2u"
    assert Vt.encode_key(vt, Event.key("a")) == "a"
  end

  test "encode_mouse and encode_focus follow modes", %{vt: vt} do
    press = {:mouse, %{kind: :press, button: :left, x: 2, y: 3, mods: [:ctrl], px: nil}}
    assert Vt.encode_mouse(vt, press) == nil
    assert Vt.encode_focus(vt, true) == ""
    Vt.set_mode(vt, 1000, true)
    Vt.set_mode(vt, 1004, true)
    assert Vt.encode_mouse(vt, press) == "\e[<16;3;4M"
    {:mouse, m} = press
    assert Vt.encode_mouse(vt, {:mouse, %{m | kind: :release, mods: []}}) == "\e[<0;3;4m"
    assert Vt.encode_focus(vt, true) == "\e[I"
    assert Vt.encode_focus(vt, false) == "\e[O"
  end

  test "close removes the pane" do
    assert {:ok, _} = Keeper.lookup(1)
    assert Keeper.pane_ids() == [1]
    assert {:error, :already_open} = Keeper.open(1, @opts)
    :ok = Keeper.close(1)
    assert Keeper.lookup(1) == :error
  end

  defp flush(acc \\ []) do
    receive do
      {:damage, _, _} = m -> flush([m | acc])
    after
      0 -> acc
    end
  end
end
