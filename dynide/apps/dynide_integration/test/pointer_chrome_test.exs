defmodule DynideIntegration.PointerChromeTest do
  @moduledoc """
  M9 pointer, bell and host caps through M13's frame (fake kernel, real client): pane
  mouse bytes pass `Hit` unchanged to `Client.Pointer`, a selection drag crossing the
  sidebar keeps its pass-through grab, a pane bell reaches the host tty, and the host's
  colour replies reach the session and Render's theme.
  """
  use ExUnit.Case, async: false

  alias DynideIntegration.Driver
  alias DynideServer.Kernel.Fake.{Keeper, Pty}
  alias DynideServer.Pane.Rows
  alias DynideTerm.Client
  alias DynideTerm.Kernel.Fake.{Desktop, Tty}

  @remote ~w(SSH_CONNECTION SSH_TTY VSCODE_IPC_HOOK_CLI)

  # copies go to the (VM-global) fake desktop clipboard: no SSH env, so no OSC 52
  setup do
    saved = Map.new(@remote, &{&1, System.get_env(&1)})
    Enum.each(@remote, &System.delete_env/1)

    on_exit(fn ->
      Desktop.reset()
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    Desktop.listen(self())
    Driver.reset()
  end

  test "a press, drag and release on a pane end in a selection" do
    c = Driver.start_client({120, 40})
    %{id: id, rect: r} = pane(c)
    # M13's frame: the sidebar is a chrome hit left of the pane
    assert r.x >= 26
    assert Enum.any?(:sys.get_state(Client.input(c)).hits, &match?([:sidebar | _], &1.path))
    Driver.output(id, "hello world from the pane\r\n")
    assert Driver.wait_screen(c, &Enum.any?(&1, fn l -> l =~ "hello world" end))

    # one pane, no border: the pane rect is its content
    drag(c, {r.x, r.y}, [{r.x + 5, r.y}, {r.x + 10, r.y}], {r.x + 10, r.y})

    # copy on select: the release copies the selection to the clipboard
    assert_receive {:desktop, :clipboard_write, "hello world"}, 2000
    assert :sys.get_state(Client.input(c)).grab == nil
  end

  test "a selection drag that crosses the sidebar keeps going to the pointer" do
    c = Driver.start_client({120, 40})
    %{id: id, rect: r} = pane(c)
    Driver.output(id, "line one\r\nline two\r\nline three\r\n")
    assert Driver.wait_screen(c, &Enum.any?(&1, fn l -> l =~ "line three" end))

    # press on "two", drag one row down over the sidebar (x 2), release there: the drag
    # clamps to column 0 of the pane
    assert r.x > 2
    drag(c, {r.x + 5, r.y + 1}, [{r.x + 3, r.y + 2}, {2, r.y + 2}], {2, r.y + 2})

    assert_receive {:desktop, :clipboard_write, "two\nl"}, 2000
    assert :sys.get_state(Client.input(c)).grab == nil
  end

  test "a pane bell reaches the foreground client's host tty as BEL" do
    c = Driver.start_client({120, 40})
    %{id: id} = pane(c)

    bells = fn ->
      c |> Driver.tty() |> Tty.written() |> String.graphemes() |> Enum.count(&(&1 == "\a"))
    end

    before = bells.()

    {:ok, %{pty: pty}} = Keeper.lookup(Rows.kernel_id(id))
    Pty.emit(pty, {:bell})

    assert wait(fn -> bells.() == before + 1 end)
  end

  test "host colour replies reach the session caps and Render's theme" do
    c = Driver.start_client({120, 40})
    tty = Driver.tty(c)
    assert wait(fn -> Tty.written(tty) =~ "\e]11;?" end, 200)

    Driver.type(c, "\e]10;rgb:0000/0000/0000\e\\\e]11;rgb:ffff/ffff/ffff\e\\\e[0n")

    render = Client.render(c)
    assert wait(fn -> :sys.get_state(render).appearance == :light end)
    assert :sys.get_state(render).theme.host == %{fg: {0, 0, 0}, bg: {255, 255, 255}}

    session = :sys.get_state(Client.input(c)).session
    assert wait(fn -> match?(%{colors: %{bg: {255, 255, 255}}}, :sys.get_state(session).caps) end)
  end

  defp pane(c), do: hd(Driver.scene(c).panes)

  defp drag(c, {px, py}, moves, {rx, ry}) do
    Driver.type(c, sgr(0, px, py, "M"))
    for {x, y} <- moves, do: Driver.type(c, sgr(32, x, y, "M"))
    Driver.type(c, sgr(0, rx, ry, "m"))
  end

  defp sgr(b, x, y, fin), do: "\e[<#{b};#{x + 1};#{y + 1}#{fin}"

  defp wait(fun, n \\ 100) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(20) && wait(fun, n - 1)
    end
  end
end
