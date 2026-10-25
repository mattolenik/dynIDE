defmodule HerdrServer.Pane.InputM9Test do
  # Paste queue, scroll snap, page keys and key fallbacks against the fake kernel.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias HerdrScene.{Event, Protocol}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.{Facts, Input, Rows, Server}

  setup do
    reset()
    on_exit(&reset/0)
    attach()
    assert eventually(fn -> Facts.get(1) != nil end)
    :ok
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

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
  defp sync(id), do: :sys.get_state(pane_pid(id))
  defp written(id), do: id |> pty() |> Fake.Pty.writes() |> IO.iodata_to_binary()

  defp scroll_back(id, n) do
    :ok = Fake.Vt.set_history(vt(id), for(i <- 1..20, do: "h#{i}"))
    Server.scroll(id, {:delta, -n})
    sync(id)
    assert Facts.scrolled?(id)
  end

  describe "paste queue" do
    test "backpressure is retried and a later key waits behind the paste" do
      :ok = Fake.Vt.set_mode(vt(1), :bracketed_paste, true)
      before = written(1)
      :ok = Fake.Pty.backpressure_next(pty(1), 3)
      data = :binary.copy("0123456789abcdef", div(4 * 1024 * 1024, 16))

      assert Input.paste(data, 1) == :ok
      assert Facts.pending?(1)
      assert Input.key(Event.key("x"), 1) == :ok

      want = before <> "\e[200~" <> data <> "\e[201~" <> "x"
      assert eventually(fn -> written(1) == want end, 300)
      assert eventually(fn -> not Facts.pending?(1) end)

      # drained: direct writes again
      assert Input.key(Event.key("y"), 1) == :ok
      assert written(1) == want <> "y"
      assert :queue.is_empty(sync(1).pending)
    end

    test "chunks are at most 64 KiB" do
      big = :binary.copy("p", 3 * 65_536 + 5)
      before = length(Fake.Pty.writes(pty(1)))
      assert Input.paste(big, 1) == :ok
      assert eventually(fn -> not Facts.pending?(1) end)
      sizes = pty(1) |> Fake.Pty.writes() |> Enum.drop(before) |> Enum.map(&byte_size/1)
      assert sizes == [65_536, 65_536, 65_536, 5]
    end

    test "a paste over the maximum is rejected and nothing is written" do
      before = written(1)
      big = :binary.copy("z", 16_777_216 + 1)
      assert {:error, {:too_large, 16_777_217, 16_777_216}} = Input.paste(big, 1)
      refute Facts.pending?(1)
      assert written(1) == before
    end

    test "an embedded end marker is removed from a bracketed paste" do
      :ok = Fake.Vt.set_mode(vt(1), :bracketed_paste, true)
      before = written(1)
      assert Input.paste("a\e[201~b", 1) == :ok
      assert eventually(fn -> written(1) == before <> "\e[200~ab\e[201~" end)
    end

    test "an unbracketed paste is written raw" do
      before = written(1)
      assert Input.paste("a\e[201~b", 1) == :ok
      assert eventually(fn -> written(1) == before <> "a\e[201~b" end)
    end

    test "a closed pty drops the queue and clears the pending flag" do
      pty = pty(1)
      :ok = Fake.Pty.set_backpressure(pty, true)
      assert Input.paste("abc", 1) == :ok
      assert Facts.pending?(1)
      assert Input.key(Event.key("x"), 1) == :ok
      sync(1)

      log =
        capture_log(fn ->
          # closed without the exit event, so the pane (and its facts row) stays
          :sys.replace_state(pty, &%{&1 | closed: true})
          :ok = Fake.Pty.set_backpressure(pty, false)
          assert eventually(fn -> not Facts.pending?(1) end)
        end)

      assert log =~ "pane 1: 2 queued writes dropped (:closed)"
      assert Facts.get(1) != nil
      assert :queue.is_empty(sync(1).pending)
    end

    test "a key behind a queued paste during a handoff is refused as closed, not queued" do
      key = HerdrScene.Protocol.handoff_key()
      on_exit(fn -> :persistent_term.erase(key) end)
      :ok = Fake.Pty.set_backpressure(pty(1), true)
      before = written(1)
      assert Input.paste("abc", 1) == :ok
      :persistent_term.put(key, :begin)
      assert Input.key(Event.key("x"), 1) == {:error, :closed}
      :persistent_term.erase(key)
      :ok = Fake.Pty.set_backpressure(pty(1), false)
      assert eventually(fn -> not Facts.pending?(1) end)
      assert written(1) == before <> "abc"
    end

    test "a paste cut short by a closed pty tells its origin how much was written" do
      :ok = Fake.Pty.close_after(pty(1), 1)
      big = :binary.copy("w", 3 * 65_536)
      assert Input.paste(big, 1, self()) == :ok

      assert_receive {:notice, %{level: :warning, text: "paste truncated after 65536 bytes"}},
                     500

      assert eventually(fn -> not Facts.pending?(1) end)
    end

    test "a restarted Pane.Server resets the pending count" do
      :ok = Facts.add_pending(1, 3)
      assert Facts.pending?(1)
      old = pane_pid(1)
      Process.exit(old, :kill)

      assert eventually(fn ->
               match?([{new, _}] when new != old, Registry.lookup(HerdrServer.Pane.Registry, 1))
             end)

      sync(1)
      refute Facts.pending?(1)
    end

    test "a facts row from before the queue (hot reload) still reads and takes a count" do
      facts = Facts.get(1)
      :ets.insert(:herdr_pane_facts, {1, %{facts | scrolled: true}})
      assert {true, false, _} = Facts.input(1)
      :ok = Facts.add_pending(1, 1)
      assert {true, true, _} = Facts.input(1)
      :ok = Facts.add_pending(1, -1)
      :ets.insert(:herdr_pane_facts, {1, facts})
      :ok = Facts.put(1, facts)
      assert [{1, ^facts, 0}] = :ets.lookup(:herdr_pane_facts, 1)
    end

    test "Pane.Server.write/2 queues bytes behind a pending paste" do
      :ok = Fake.Pty.backpressure_next(pty(1), 2)
      before = written(1)
      :ok = Fake.Vt.set_mode(vt(1), :focus_events, true)
      assert Input.paste("one", 1) == :ok
      assert Server.write(1, ["t", "wo"]) == :ok
      assert Input.focus(true, 1) == :ok
      assert eventually(fn -> written(1) == before <> "onetwo\e[I" end)
      assert eventually(fn -> not Facts.pending?(1) end)
    end
  end

  describe "snap to bottom" do
    test "a key while scrolled back snaps the viewport and writes the key" do
      scroll_back(1, 5)
      before = written(1)
      assert Input.key(Event.key("k"), 1) == :ok
      sync(1)
      refute Facts.scrolled?(1)
      %{total: t, viewport: v, offset: o} = Fake.Vt.scrollbar(vt(1))
      assert o == t - v
      assert written(1) == before <> "k"
    end

    test "a key release does not snap" do
      scroll_back(1, 5)
      Input.key(Event.key("k", [], event: :release), 1)
      sync(1)
      assert Facts.scrolled?(1)
    end

    test "a paste and a mouse press snap; a mouse move does not" do
      scroll_back(1, 5)
      Input.mouse(mouse(:move), 1)
      sync(1)
      assert Facts.scrolled?(1)
      Input.mouse(mouse(:press), 1)
      sync(1)
      refute Facts.scrolled?(1)

      scroll_back(1, 5)
      assert Input.paste("p", 1) == :ok
      sync(1)
      refute Facts.scrolled?(1)
    end
  end

  describe "page keys" do
    setup do
      :ok = Fake.Vt.set_history(vt(1), for(i <- 1..60, do: "h#{i}"))
      sync(1)
      %{rows: Fake.Vt.scrollbar(vt(1)).viewport}
    end

    test "plain page up/down scroll the host scrollback by the viewport height", %{rows: rows} do
      before = written(1)
      %{offset: bottom} = Fake.Vt.scrollbar(vt(1))
      assert Input.key(Event.key(:page_up), 1) == :ok
      sync(1)
      assert Fake.Vt.scrollbar(vt(1)).offset == bottom - rows
      assert Input.key(Event.key(:page_up, [], event: :release), 1) == :ok
      assert Input.key(Event.key(:page_down), 1) == :ok
      sync(1)
      assert Fake.Vt.scrollbar(vt(1)).offset == bottom
      assert written(1) == before
    end

    test "on the alternate screen page up goes to the child" do
      :ok = Fake.Vt.set_mode(vt(1), :alt_screen, true)
      # the alt-screen fact is read on damage with dirty rows
      Fake.Pty.output(pty(1), "z")
      assert eventually(fn -> Facts.get(1).alt_screen end)
      before = written(1)
      %{offset: bottom} = Fake.Vt.scrollbar(vt(1))
      assert Input.key(Event.key(:page_up), 1) == :ok
      assert written(1) == before <> "\e[5~"
      assert Fake.Vt.scrollbar(vt(1)).offset == bottom
    end

    test "mouse tracking, or app cursor keys without bracketed paste, send the key" do
      for {modes, sent?} <- [
            {[mouse_any: true], true},
            {[cursor_keys: true], true},
            {[cursor_keys: true, bracketed_paste: true], false}
          ] do
        for m <- [:mouse_any, :cursor_keys, :bracketed_paste],
            do: :ok = Fake.Vt.set_mode(vt(1), m, Keyword.get(modes, m, false))

        before = written(1)
        Input.key(Event.key(:page_down), 1)
        sync(1)
        assert written(1) == if(sent?, do: before <> "\e[6~", else: before), inspect(modes)
      end
    end

    test "caps lock and num lock do not stop page keys scrolling the host", %{rows: rows} do
      before = written(1)
      %{offset: bottom} = Fake.Vt.scrollbar(vt(1))
      assert Input.key(Event.key(:page_up, [:caps_lock, :num_lock]), 1) == :ok
      sync(1)
      assert Fake.Vt.scrollbar(vt(1)).offset == bottom - rows
      assert written(1) == before
    end

    test "host_scroll: false sends page keys to the child" do
      before = written(1)
      %{offset: bottom} = Fake.Vt.scrollbar(vt(1))
      assert Input.key(Event.key(:page_up), 1, host_scroll: false) == :ok
      assert written(1) == before <> "\e[5~"
      assert Fake.Vt.scrollbar(vt(1)).offset == bottom
    end

    test "page up with a modifier goes to the child" do
      before = written(1)
      Input.key(Event.key(:page_up, [:shift]), 1)
      assert written(1) == before <> "\e[5;2~"
    end
  end

  describe "key fallbacks" do
    test "a legacy pane gets ctrl+m as enter and drops super chords" do
      before = written(1)
      Input.key(Event.key("m", [:ctrl]), 1)
      Input.key(Event.key("c", [:super]), 1)
      Input.key(Event.key(:enter, [:shift]), 1)
      assert written(1) == before <> "\r\r"
    end

    test "a kitty-negotiated pane gets the encoded chord" do
      :ok = Fake.Vt.set_kitty_flags(vt(1), 1)
      before = written(1)
      Input.key(Event.key(:enter, [:shift]), 1)
      assert written(1) == before <> "\e[13;2u"
    end
  end

  defp mouse(kind),
    do: {:mouse, %{kind: kind, button: :left, x: 0, y: 0, mods: [], px: nil}}

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
