defmodule DynideServer.Kernel.FakeTest do
  use ExUnit.Case, async: false

  alias DynideScene.{Cell, Event}
  alias DynideScene.Scene.Graphic
  alias DynideServer.Kernel
  alias DynideServer.Kernel.Fake.{Keeper, Pty, Vt}

  @opts %{cmd: "sh", args: [], env: [], cwd: "/", cols: 20, rows: 5, max_scrollback: 0}

  setup do
    {:ok, id} = Keeper.open(Map.put(@opts, :subscriber, self()))
    on_exit(fn -> Keeper.close(id) end)
    {:ok, %{vt: vt, pty: pty}} = Keeper.lookup(id)
    assert_receive {:damage, ^id, _}
    # drain the forced full damage
    Vt.dirty_rows(vt)
    {:ok, id: id, vt: vt, pty: pty}
  end

  defp text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))

  test "kernel modules resolve to the fake in test" do
    assert Application.get_env(:dynide_server, :kernel)[:keeper] == Keeper
    assert Kernel.vt() == Vt
    assert Kernel.pty() == Pty
    assert Kernel.keeper() == Keeper
  end

  test "set_graphics feeds graphics_placements and graphics_image", %{vt: vt} do
    assert Vt.graphics_placements(vt) == []
    assert Vt.graphics_image(vt, 7) == nil

    p = %{
      image: {7, 1},
      placement: 1,
      x: 0,
      y: 0,
      cols: 2,
      rows: 1,
      x_off: 0,
      y_off: 0,
      src: {0, 0, 0, 0},
      px: {0, 0},
      z: 0,
      size: {1, 1},
      format: :rgb,
      bytes: 3
    }

    assert Graphic.validate(p) == :ok
    img = %{format: :rgb, width: 1, height: 1, bytes: 3, data: <<1, 2, 3>>}
    :ok = Vt.set_graphics(vt, [p], %{7 => img})
    assert Vt.graphics_placements(vt) == [p]
    assert Vt.graphics_image(vt, 7) == img
    assert Vt.graphics_image(vt, 8) == nil
  end

  test "write echoes, damage once, dirty rows consumed", %{id: id, vt: vt, pty: pty} do
    :ok = Pty.write(pty, "hi")
    assert_receive {:damage, ^id, gen}, 50
    assert {^gen, [{0, row}]} = Vt.dirty_rows(vt)
    assert String.starts_with?(text(row), "hi")
    assert {^gen, []} = Vt.dirty_rows(vt)
  end

  test "resubscribe forces full damage", %{id: id, vt: vt, pty: pty} do
    :ok = Pty.subscribe(pty, self())
    assert_receive {:damage, ^id, _}
    assert {_, rows} = Vt.dirty_rows(vt)
    assert Enum.map(rows, &elem(&1, 0)) == [0, 1, 2, 3, 4]
  end

  test "output interprets CR LF, cursor, clear, home", %{id: id, vt: vt, pty: pty} do
    Pty.output(pty, "a\r\nb")
    assert_receive {:damage, ^id, _}, 50
    assert %{x: 1, y: 1} = Vt.cursor(vt)
    assert Vt.read_text(vt, :viewport) == "a\nb\n\n\n"
    Pty.output(pty, "\e[2;5Hz\e[Hq\e[31m!\e[2J")
    assert_receive {:damage, ^id, _}, 50
    assert Vt.read_text(vt, :screen) == "\n\n\n\n"
    Pty.output(pty, "\e[Hab\b\bx\ty")
    assert_receive {:damage, ^id, _}, 50
    assert Vt.read_text(vt, {:rows, 0..0}) == "xb      y"
  end

  test "scrolls at the bottom", %{id: id, vt: vt, pty: pty} do
    Pty.output(pty, "1\n2\n3\n4\n5\n6")
    assert_receive {:damage, ^id, _}, 50

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

  test "a large chunk interprets only the visible tail", %{id: id, vt: vt, pty: pty} do
    Pty.output(pty, String.duplicate("é", 1_000_000) <> "\r\nend")
    assert_receive {:damage, ^id, _}, 500
    assert Vt.read_text(vt, :viewport) |> String.contains?("end")
    assert {_, [_ | _]} = Vt.dirty_rows(vt)
  end

  test "hidden suppresses damage but rows update", %{id: id, vt: vt, pty: pty} do
    :ok = Pty.set_hidden(pty, true)
    Pty.output(pty, "q")
    refute_receive {:damage, _, _}, 20
    assert Vt.read_text(vt, {:rows, 0..0}) |> String.starts_with?("q")
    :ok = Pty.set_hidden(pty, false)
    assert_receive {:damage, ^id, _}
  end

  test "kill notifies subscribers with the pane id", %{id: id, pty: pty} do
    :ok = Pty.kill(pty, :term)
    assert_receive {:exit, ^id, {:signal, 15}}
    assert Pty.write(pty, "x") == {:error, :closed}
  end

  test "writes over 1 MiB are too large", %{pty: pty} do
    assert Pty.write(pty, :binary.copy("x", 1_048_577)) == {:error, :too_large}
  end

  test "resize keeps content", %{vt: vt, pty: pty} do
    Pty.output(pty, "hey")
    :ok = Pty.resize(pty, 10, 3, nil)
    assert Vt.read_text(vt, :viewport) == "hey\n\n"
    assert {_, [_, _, _]} = Vt.dirty_rows(vt)
  end

  defp k(key, mods \\ [], opts \\ []), do: key |> Event.key(mods, opts) |> elem(1)

  test "encode_key", %{vt: vt} do
    assert Vt.encode_key(vt, k("a")) == "a"
    assert Vt.encode_key(vt, k("c", [:ctrl])) == <<3>>
    assert Vt.encode_key(vt, k("x", [:alt])) == "\ex"
    assert Vt.encode_key(vt, k(:up, [:shift])) == "\e[1;2A"
    assert Vt.encode_key(vt, k(:up)) == "\e[A"
    assert Vt.encode_key(vt, k(:enter)) == "\r"
    assert Vt.encode_key(vt, k(:backspace)) == "\x7f"
    assert Vt.encode_key(vt, k(:page_up)) == "\e[5~"
    assert Vt.encode_key(vt, k(:f1)) == "\eOP"
    assert Vt.encode_key(vt, k(:f5, [:ctrl])) == "\e[15;5~"
    assert Vt.encode_key(vt, k("a", [], event: :release)) == ""
    Vt.set_kitty_flags(vt, 1)
    assert Vt.kitty_keyboard_flags(vt) == 1
    assert Vt.encode_key(vt, k("a", [:ctrl])) == "\e[97;5u"
    assert Vt.encode_key(vt, k(:enter, [:shift])) == "\e[13;2u"
    assert Vt.encode_key(vt, k("a")) == "a"
  end

  test "encode_mouse and encode_focus follow modes", %{vt: vt} do
    press = %{kind: :press, button: :left, x: 2, y: 3, mods: [:ctrl], px: nil}
    assert Vt.encode_mouse(vt, press) == nil
    assert Vt.encode_focus(vt, true) == ""
    Vt.set_mode(vt, :mouse_normal, true)
    Vt.set_mode(vt, :focus_events, true)
    assert Vt.encode_mouse(vt, press) == "\e[<16;3;4M"
    assert Vt.encode_mouse(vt, %{press | kind: :release, mods: []}) == "\e[<0;3;4m"
    assert Vt.encode_focus(vt, true) == "\e[I"
    assert Vt.encode_focus(vt, false) == "\e[O"
  end

  test "activity counts output, hidden or not", %{pty: pty} do
    assert Pty.activity(pty) == 0
    Pty.output(pty, "a")
    :ok = Pty.set_hidden(pty, true)
    Pty.output(pty, "b")
    assert Pty.activity(pty) == 2
  end

  test "foreground is the shell until set_foreground", %{id: id, pty: pty} do
    {:ok, %{os_pid: os_pid}} = Keeper.lookup(id)
    assert Pty.foreground_job(pty) == %{pgid: os_pid, shell: true, processes: []}
    assert Pty.foreground_pgid(pty) == os_pid
    job = %{pgid: 7, shell: false, processes: [%{pid: 7, name: "claude", argv: ["claude"]}]}
    :ok = Pty.set_foreground(pty, job)
    assert Pty.foreground_job(pty) == job
    assert Pty.foreground_pgid(pty) == 7
    :ok = Pty.set_foreground(pty, nil)
    assert Pty.foreground_job(pty) == nil
    assert Pty.foreground_pgid(pty) == nil
  end

  test "cwd is the spawn cwd until set_cwd", %{pty: pty} do
    assert Pty.cwd(pty) == "/"
    :ok = Pty.set_cwd(pty, "/tmp")
    assert Pty.cwd(pty) == "/tmp"
    :ok = Pty.set_cwd(pty, nil)
    assert Pty.cwd(pty) == nil
  end

  test "tail_ansi returns the last text rows, :alt_screen in alt mode", %{
    id: id,
    vt: vt,
    pty: pty
  } do
    assert Vt.tail_ansi(vt, 3) == ""
    Pty.output(pty, "a\r\nb\r\nc")
    assert_receive {:damage, ^id, _}, 50
    assert Vt.tail_ansi(vt, 2) == "b\r\nc"
    assert Vt.tail_ansi(vt, 10) == "a\r\nb\r\nc"
    assert Vt.tail_ansi(vt, 0) == ""
    :ok = Vt.set_mode(vt, :alt_screen, true)
    assert Vt.tail_ansi(vt, 2) == :alt_screen
  end

  test "keeper replays into the new vt and records cmd" do
    {:ok, id} =
      Keeper.open(Map.merge(@opts, %{replay: "hello\r\n", args: ["-l"], subscriber: nil}))

    {:ok, %{vt: vt, cmd: cmd}} = Keeper.lookup(id)
    assert cmd == ["sh", "-l"]
    assert Vt.read_text(vt, :screen) =~ "hello"
    Keeper.close(id)
    {:ok, id} = Keeper.open(Map.merge(@opts, %{replay: nil, subscriber: nil}))
    Keeper.close(id)
  end

  test "colours and scheme are recorded", %{vt: vt} do
    assert Vt.colors(vt) == %{colors: nil, scheme: nil}
    assert :ok = Vt.set_colors(vt, %{fg: {1, 2, 3}, palette: %{1 => {255, 0, 0}}})
    assert :ok = Vt.set_color_scheme(vt, :dark)

    assert Vt.colors(vt) == %{
             colors: %{fg: {1, 2, 3}, palette: %{1 => {255, 0, 0}}},
             scheme: :dark
           }

    assert Vt.modify_other_keys(vt) == false
  end

  test "no history: offset 0, total = viewport = rows, scroll_to is a no-op", %{vt: vt, pty: pty} do
    :ok = Pty.write(pty, "hi")
    assert_receive {:damage, _, _}, 50
    assert Vt.scrollbar(vt) == %{total: 5, viewport: 5, offset: 0}
    assert :ok = Vt.scroll_to(vt, 3)
    assert Vt.scrollbar(vt) == %{total: 5, viewport: 5, offset: 0}
    {_, [{0, row} | _]} = Vt.full_rows(vt)
    assert String.starts_with?(text(row), "hi")
  end

  test "history: scroll_to moves the viewport over history rows", %{vt: vt, pty: pty} do
    :ok = Pty.write(pty, "live")
    assert_receive {:damage, _, _}, 50
    Vt.dirty_rows(vt)
    :ok = Vt.set_history(vt, ["h0", "h1", "h2"])
    assert Vt.scrollbar(vt) == %{total: 8, viewport: 5, offset: 3}
    assert :ok = Vt.scroll_to(vt, 1)
    assert Vt.scrollbar(vt) == %{total: 8, viewport: 5, offset: 1}
    {_, rows} = Vt.dirty_rows(vt)
    assert length(rows) == 5

    assert Enum.map(rows, fn {_, r} -> String.trim_trailing(text(r)) end) ==
             ["h1", "h2", "live", "", ""]

    {_, [{0, r0} | _]} = Vt.full_rows(vt)
    assert String.trim_trailing(text(r0)) == "h1"
    assert Vt.read_text(vt, :viewport) |> String.split("\n") |> hd() == "h1"
    assert Vt.read_text(vt, {:rows, 0..0}) == "h0"
    # past the end clamps to the bottom
    :ok = Vt.scroll_to(vt, 99)
    assert Vt.scrollbar(vt).offset == 3
  end

  test "selection text and screen rows slice the screen lines", %{vt: vt, pty: pty} do
    :ok = Vt.set_history(vt, ["hello world"])
    :ok = Pty.write(pty, "abc")
    assert_receive {:damage, _, _}, 50
    assert Vt.read_text(vt, {:selection, {6, 0}, {10, 0}}) == "world"
    assert Vt.read_text(vt, {:selection, {1, 1}, {6, 0}}) == "world\nab"
    assert Vt.read_text(vt, {:selection, {0, 0}, {99, 99}}) == "hello world\nabc"
    rows = Vt.screen_rows(vt, 0, 100)
    assert Enum.map(rows, &elem(&1, 0)) == [0, 1, 2, 3, 4, 5]
    assert [{0, r0, false}, {1, r1, false} | _] = rows
    assert Cell.cols(r0) == 20
    assert String.trim_trailing(text(r0)) == "hello world"
    assert String.trim_trailing(text(r1)) == "abc"
    assert Vt.screen_rows(vt, 50, 60) == []
  end

  test "close removes the pane", %{id: id} do
    assert {:ok, _} = Keeper.lookup(id)
    {:ok, id2} = Keeper.open(Map.put(@opts, :subscriber, nil))
    assert id2 > id
    assert Enum.take(Keeper.ids(), -2) == [id, id2]
    :ok = Keeper.close(id)
    assert Keeper.lookup(id) == :error
    assert id2 in Keeper.ids()
    :ok = Keeper.close(id2)
  end

  defp flush(acc \\ []) do
    receive do
      {:damage, _, _} = m -> flush([m | acc])
    after
      0 -> acc
    end
  end
end
