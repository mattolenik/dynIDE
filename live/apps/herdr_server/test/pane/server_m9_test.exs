defmodule HerdrServer.Pane.ServerM9Test do
  # Pane facts, OSC trackers, scrolling and foreground routing against the fake kernel.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.Protocol
  alias HerdrServer.App.Store
  alias HerdrServer.Client.Foreground
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.{Facts, Rows, Server, State}

  setup do
    reset()
    on_exit(&reset/0)
    attach()
    # this test process sees what every client session sees
    {:ok, _} = Registry.register(HerdrServer.Client.Registry, :clients, nil)
    assert eventually(fn -> Facts.get(1) != nil end)
    :ok
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

    :ets.delete(:herdr_pane_facts, :host_colors)
    :ets.delete(:herdr_pane_facts, :foreground)
    Store.reset()
  end

  defp attach do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: %{cols: 80, rows: 24},
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, GenServer.call(Protocol.endpoint(), {:attach, info})})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, {:ok, _session, _}}
  end

  defp res(id), do: elem(Fake.Keeper.lookup(Rows.kernel_id(id)), 1)
  defp vt(id), do: res(id).vt
  defp pty(id), do: res(id).pty
  defp pane_pid(id), do: Registry.lookup(HerdrServer.Pane.Registry, id) |> hd() |> elem(0)

  defp listener do
    parent = self()
    spawn_link(fn -> relay(parent) end)
  end

  defp relay(parent) do
    receive do
      msg -> send(parent, {self(), msg})
    end

    relay(parent)
  end

  # stop + start, not a kill: kills count against the pane supervisor's restart intensity
  defp restart_pane(id) do
    old = pane_pid(id)
    :ok = HerdrServer.Pane.Supervisor.stop_pane(id)
    {:ok, new} = HerdrServer.Pane.Supervisor.start_pane(id)
    assert new != old
  end

  defp sync(id), do: :sys.get_state(pane_pid(id))

  defp drain do
    receive do
      {:pane_facts, _} -> drain()
      {:pane_damage, _, _} -> drain()
    after
      50 -> :ok
    end
  end

  describe "scroll" do
    setup do
      lines = for n <- 1..20, do: "h#{n}"
      :ok = Fake.Vt.set_history(vt(1), lines)
      drain()
      %{viewport: rows} = Fake.Vt.scrollbar(vt(1))
      %{rows: rows}
    end

    test "delta up marks the pane scrolled, bottom clears it, sessions are told", %{rows: rows} do
      Server.scroll(1, {:delta, -5})
      assert_receive {:pane_facts, 1}, 500
      total = 20 + rows

      assert %{scrolled: true, scroll: %{total: ^total, viewport: ^rows, offset: 15}} =
               Facts.get(1)

      assert Facts.scrolled?(1)

      Server.scroll(1, :bottom)
      assert_receive {:pane_facts, 1}, 500
      assert %{scrolled: false, scroll: %{offset: 20}} = Facts.get(1)
      refute Facts.scrolled?(1)
    end

    test "deltas clamp and top jumps to a row" do
      Server.scroll(1, {:delta, -500})
      assert_receive {:pane_facts, 1}, 500
      assert Facts.get(1).scroll.offset == 0

      Server.scroll(1, {:top, 7})
      assert_receive {:pane_facts, 1}, 500
      assert Facts.get(1).scroll.offset == 7

      Server.scroll(1, {:delta, 500})
      assert_receive {:pane_facts, 1}, 500
      refute Facts.scrolled?(1)
    end

    test "scrolling repaints the viewport" do
      Server.scroll(1, {:top, 0})
      assert_receive {:pane_damage, 1, _}, 500
      {_gen, rows, _} = Rows.fetch(1)
      assert HerdrScene.Cell.decode_row(elem(rows, 0)) |> Enum.map_join(& &1.glyph) =~ "h1"
    end

    test "damage of an unscrolled pane sends no facts" do
      Fake.Pty.output(pty(1), "abc\r\n")
      assert_receive {:pane_damage, 1, _}, 500
      refute_receive {:pane_facts, 1}, 100
    end

    test "resize keeps the distance from the bottom" do
      Server.scroll(1, {:delta, -5})
      assert_receive {:pane_facts, 1}, 500
      :ok = Server.resize(1, 80, 10, nil)
      assert %{scrolled: true, scroll: %{total: 30, viewport: 10, offset: 15}} = Facts.get(1)
    end
  end

  test "a bell reaches only the marked foreground client" do
    a = listener()
    b = listener()
    :ok = Foreground.mark(a)
    Fake.Pty.emit(pty(1), {:bell})
    assert_receive {^a, {:pane_bell, 1}}, 500
    refute_receive {^b, _}, 100
    refute_receive {:pane_bell, _}
  end

  test "mark writes only on change and send drops when the client is gone" do
    a = spawn(fn -> :ok end)
    :ok = Foreground.mark(a)
    assert :ets.lookup(:herdr_pane_facts, :foreground) == [{:foreground, a}]
    assert Foreground.send(:hello) == :ok
  end

  test "osc 52 from the child goes to the foreground client" do
    a = listener()
    :ok = Foreground.mark(a)
    Fake.Pty.emit(pty(1), {:osc, 52, "c;" <> Base.encode64("hi")})
    assert_receive {^a, {:pane_clipboard, 1, "hi"}}, 500
  end

  test "osc 7 for an existing directory sets the cwd" do
    dir = File.cwd!()
    Fake.Pty.emit(pty(1), {:pwd, "file://localhost" <> URI.encode(dir)})
    assert eventually(fn -> Facts.get(1).cwd == dir end)

    Fake.Pty.emit(pty(1), {:pwd, "file://localhost/no/such/dir/here"})
    Fake.Pty.emit(pty(1), {:osc, 1337, "CurrentDir=/no/such/either"})
    sync(1)
    assert Facts.get(1).cwd == dir

    Fake.Pty.emit(pty(1), {:osc, 9, "9;/"})
    assert eventually(fn -> Facts.get(1).cwd == "/" end)
  end

  test "osc 9 progress is kept" do
    Fake.Pty.emit(pty(1), {:osc, 9, "4;3;"})
    assert eventually(fn -> Facts.get(1).progress == "4;3;" end)
  end

  test "titles are sanitized and kept stripped" do
    Fake.Pty.emit(pty(1), {:title, "⠋ cla\eude"})
    assert eventually(fn -> Facts.get(1)[:stripped_title] == "claude" end)
    assert Facts.get(1).title == "⠋ claude"
    assert eventually(fn -> Store.snapshot().session.panes[1].title == "⠋ claude" end)

    Fake.Pty.emit(pty(1), {:title, ""})
    assert eventually(fn -> Facts.get(1).title == nil end)
  end

  test "the default cursor style is published as :default" do
    Fake.Pty.output(pty(1), "a")

    assert eventually(fn ->
             match?({_, _, %{shape: :default, blinking: false}}, Rows.fetch(1))
           end)

    :ok = Fake.Vt.set_cursor_shape(vt(1), :bar)
    Fake.Pty.output(pty(1), "b")
    assert eventually(fn -> match?({_, _, %{shape: :bar}}, Rows.fetch(1)) end)

    :ok = Fake.Vt.set_cursor_shape(vt(1), :block, true)
    Fake.Pty.output(pty(1), "c")
    assert eventually(fn -> match?({_, _, %{shape: :block, blinking: true}}, Rows.fetch(1)) end)
  end

  test "init applies the host colours" do
    colors = %{fg: {1, 2, 3}, bg: {4, 5, 6}, palette: %{1 => {255, 0, 0}}}
    :ok = Facts.put_host_colors(%{colors: colors, scheme: :dark})
    :ok = Facts.put_host_colors(%{scheme: :light})
    restart_pane(1)

    assert Fake.Vt.colors(vt(1)) == %{colors: colors, scheme: :light}
    assert sync(1).colors == colors
  end

  test "a restart keeps cwd and title facts" do
    Fake.Pty.emit(pty(1), {:osc, 9, "9;/"})
    assert eventually(fn -> Facts.get(1).cwd == "/" end)
    restart_pane(1)

    assert sync(1).cwd == "/"
    assert Facts.get(1).cwd == "/"
  end

  test "deleting a pane's rows deletes its facts" do
    :ok = Facts.put(99, %{scrolled: true})
    :ok = Rows.delete(99)
    assert Facts.get(99) == nil
  end

  test "code_change merges new defaults" do
    assert {:ok, %State{scroll: %{total: 0, viewport: 0, offset: 0}, cwd: nil}} =
             Server.code_change(:old, %{id: 9, rows: {}}, nil)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
