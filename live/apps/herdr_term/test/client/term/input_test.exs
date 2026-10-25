defmodule HerdrTerm.Client.Term.InputTest do
  # the fast-path term is VM-global
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.Protocol
  alias HerdrTerm.Client
  alias HerdrTerm.Kernel.Fake.Tty
  alias HerdrTerm.Test.FakeServer

  def rows(_id), do: nil
  def key(ev, test), do: send(test, {:fast, ev})

  setup do
    on_exit(fn -> :persistent_term.erase(Protocol.fast_path_key()) end)
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []})
    sup = start_supervised!({Client, endpoint: ep})
    assert_receive {:attached, %{kind: :term, size: %{cols: 80, rows: 24}}, session}
    %{sup: sup, tty: Client.tty(sup), session: session}
  end

  defp fast(intercept) do
    :persistent_term.put(Protocol.fast_path_key(), %{
      gen: 1,
      pane: 1,
      write: {__MODULE__, :key, [self()]},
      intercept: MapSet.new(intercept),
      passthrough: true
    })
  end

  test "leaves the probe to the tty kernel and consumes late replies", %{tty: tty} do
    refute Tty.written(tty) =~ "\e[?u"
    Tty.inject(tty, "\e[?1u")
    refute_receive {:input, _, _, _}, 50
  end

  test "slow events wait for the ack of the previous one", %{tty: tty} do
    Tty.inject(tty, "ab")
    assert_receive {:input, from, 1, {:key, %{key: "a"}}}
    refute_receive {:input, _, 2, _}, 50
    send(from, {:ack, 1})
    assert_receive {:input, ^from, 2, {:key, %{key: "b"}}}
  end

  test "fast path writes through the MFA and sends nothing", %{tty: tty} do
    fast([])
    Tty.inject(tty, "z")
    assert_receive {:fast, {:key, %{key: "z"}}}
    refute_receive {:input, _, _, _}, 50
  end

  test "an inline (socket) client never takes the in-VM fast path" do
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []})
    sup = start_supervised!({Client, endpoint: ep, transport: :inline}, id: :inline_client)
    assert_receive {:attached, %{transport: :inline}, _session}, 2_000
    fast([])
    Tty.inject(Client.tty(sup), "z")
    assert_receive {:input, _, 1, {:key, %{key: "z"}}}, 2_000
    refute_receive {:fast, _}, 100
  end

  test "an intercepted key goes slow and holds the next one until acked", %{tty: tty} do
    fast([{"b", [:ctrl]}])
    Tty.inject(tty, "\x02v")
    assert_receive {:input, from, 1, {:key, %{key: "b", mods: [:ctrl]}}}
    refute_receive {:fast, _}, 50
    send(from, {:ack, 1})
    assert_receive {:fast, {:key, %{key: "v"}}}
  end

  test "in its own prefix mode the next key goes slow despite a passthrough record",
       %{tty: tty} do
    fast([{"b", [:ctrl]}])
    Tty.inject(tty, "\x02x")
    assert_receive {:input, from, 1, {:key, %{key: "b", mods: [:ctrl]}}}
    send(from, {:input_mode, :prefix})
    send(from, {:ack, 1})
    assert_receive {:input, ^from, 2, {:key, %{key: "x"}}}
    refute_received {:fast, _}
    send(from, {:input_mode, :terminal})
    send(from, {:ack, 2})
    Tty.inject(tty, "y")
    assert_receive {:fast, {:key, %{key: "y"}}}
  end

  test "a new session starts the client in terminal mode", %{sup: sup, tty: tty} do
    fast([])
    input = Client.input(sup)
    send(input, {:input_mode, :prefix})
    send(input, {:session, spawn(fn -> :ok end)})
    Tty.inject(tty, "q")
    assert_receive {:fast, {:key, %{key: "q"}}}
  end

  test "a lone escape flushes after the timeout", %{tty: tty} do
    Tty.inject(tty, "\e")
    assert_receive {:input, _, 1, {:key, %{key: :escape}}}, 200
  end

  test "sigwinch sends a resize event", %{sup: sup, tty: tty} do
    Tty.set_size(tty, {100, 30, 800, 600})
    send(Client.owner(sup), :sigwinch)
    assert_receive {:input, _, 1, {:resize, %{cols: 100, rows: 30, cell_px: {8, 20}}}}
  end

  test "a restarted input re-subscribes and gets the session", %{sup: sup, tty: tty} do
    ref = Process.monitor(Client.input(sup))
    Process.exit(Client.input(sup), :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_until(fn -> Client.input(sup) end)
    wait_until(fn -> :sys.get_state(Client.input(sup)).session end)
    Tty.inject(tty, "q")
    assert_receive {:input, _, 1, {:key, %{key: "q"}}}
  end

  test "key releases never take the fast path", %{tty: tty} do
    fast([])
    Tty.inject(tty, "\e[97;1:3u")
    assert_receive {:input, _, 1, {:key, %{key: "a", event: :release}}}
    refute_receive {:fast, _}, 50
  end

  test "an unacked event is re-sent first to the next session", %{tty: tty, session: session} do
    Tty.inject(tty, "a")
    assert_receive {:input, _, 1, {:key, %{key: "a"}}}
    Process.exit(session, :kill)
    Tty.inject(tty, "b")
    assert_receive {:attached, _, session2}
    assert session2 != session
    assert_receive {:input, from, seq, {:key, %{key: "a"}}}
    refute_receive {:input, _, _, _}, 50
    send(from, {:ack, seq})
    assert_receive {:input, ^from, _, {:key, %{key: "b"}}}
  end

  test "unknown messages are ignored; resume and tty exit go to Tty.Owner", %{sup: sup} do
    input = Client.input(sup)
    before = :sys.get_state(input)
    send(input, :bogus)
    assert :sys.get_state(input) == before
    :erlang.trace(Client.owner(sup), true, [:receive])
    send(input, {:tty_resumed})
    assert_receive {:trace, _, :receive, {:tty_resumed}}, 500
    send(input, {:exit, :tty, :hangup})
    assert_receive {:trace, _, :receive, {:exit, :tty, :hangup}}, 500
    assert Process.alive?(input)
  end

  test "a failing Parse drops the chunk and keeps the Input state", %{sup: sup, tty: tty} do
    input = Client.input(sup)
    :sys.replace_state(input, &%{&1 | parse: :broken})
    before = :sys.get_state(input)
    Tty.inject(tty, "a")
    send(input, {:esc_flush, before.esc})
    assert :sys.get_state(input) == %{before | esc: nil}
    refute_receive {:input, _, _, _}, 50
    assert Client.input(sup) == input
  end

  test "pointer moves behind an in-flight event coalesce to the newest", %{tty: tty, sup: sup} do
    Tty.inject(tty, "a")
    assert_receive {:input, from, 1, {:key, %{key: "a"}}}
    for x <- 1..50, do: Tty.inject(tty, "\e[<35;#{x};1M")
    Tty.inject(tty, "b")
    :sys.get_state(Client.input(sup))
    send(from, {:ack, 1})
    assert_receive {:input, ^from, 2, {:mouse, %{kind: :move, x: 49}}}
    send(from, {:ack, 2})
    assert_receive {:input, ^from, 3, {:key, %{key: "b"}}}
    send(from, {:ack, 3})
    refute_receive {:input, _, _, _}, 50
  end

  describe "host colours" do
    defp palette_replies(range),
      do: for(n <- range, into: "", do: "\e]4;#{n};rgb:#{hex(n)}/00/00\e\\")

    defp hex(n), do: n |> Integer.to_string(16) |> String.pad_leading(2, "0")

    defp queried(tty, times),
      do: tty |> Tty.written() |> String.split("\e[?996n") |> length() > times

    test "queries the host after the startup windows and sends the answers as caps",
         %{sup: sup, tty: tty} do
      assert wait_until(fn -> queried(tty, 1) end, 200)
      w = Tty.written(tty)
      assert w =~ "\e]10;?\e\\\e]11;?\e\\"
      assert String.ends_with?(w, "\e]4;255;?\e\\\e[5n")
      assert w =~ "\e]4;0;?\e\\" and w =~ "\e]4;255;?\e\\"

      Tty.inject(tty, "\e[?997;1n\e]10;rgb:ffff/ffff/ffff\e\\\e]11;rgb:1e1e/1e1e/2e2e\e\\")
      Tty.inject(tty, palette_replies(0..255))
      # all 258 colour replies: no need to wait for the 1 s window
      assert_receive {:caps,
                      %{
                        colors: %{fg: {255, 255, 255}, bg: {30, 30, 46}, palette: p},
                        scheme: :dark
                      }},
                     500

      assert map_size(p) == 256 and p[255] == {255, 0, 0}

      assert :sys.get_state(Client.render(sup)).theme.host == %{
               fg: {255, 255, 255},
               bg: {30, 30, 46}
             }

      refute_receive {:input, _, _, _}, 50

      # a later scheme report alone, and the colours are asked again
      Tty.inject(tty, "\e[?997;2n")
      assert_receive {:caps, caps}
      assert caps == %{scheme: :light}
      assert wait_until(fn -> queried(tty, 2) end)

      # a new session gets the latest caps
      send(Client.input(sup), {:session, self()})
      assert_receive {:caps, %{colors: %{fg: {255, 255, 255}}, scheme: :light}}
    end

    test "a late report of the scheme already sent does not query again", %{tty: tty} do
      assert wait_until(fn -> queried(tty, 1) end, 200)
      Tty.inject(tty, "\e[?997;1n\e]10;rgb:ffff/ffff/ffff\e\\\e[0n")
      assert_receive {:caps, %{scheme: :dark}}, 500
      # e.g. the answer to the query a slow host replied to after the window closed
      Tty.inject(tty, "\e[?997;1n")
      refute_receive {:caps, _}, 200
      refute queried(tty, 2)
      # a real change still re-queries
      Tty.inject(tty, "\e[?997;2n")
      assert_receive {:caps, %{scheme: :light}}, 500
      assert wait_until(fn -> queried(tty, 2) end)
    end

    test "the colour window follows :colors_window_ms", %{tty: tty, sup: sup} do
      old = Application.get_env(:herdr_term, :colors_window_ms)
      on_exit(fn -> Application.put_env(:herdr_term, :colors_window_ms, old) end)
      Application.put_env(:herdr_term, :colors_window_ms, 300)
      assert wait_until(fn -> queried(tty, 1) end, 200)
      # a query started now uses the 300 ms window (the startup one's timer goes stale)
      send(Client.input(sup), {:tty_resumed})
      assert wait_until(fn -> queried(tty, 2) end, 200)
      Tty.inject(tty, "\e]11;rgb:ff/ff/ff\a")
      refute_receive {:caps, _}, 150
      # accepted inside the window, sent when it closes at 300 ms, well before 1 s
      assert_receive {:caps, %{colors: %{bg: {255, 255, 255}}}}, 450
    end

    test "a partial answer is sent when the window closes; resume re-queries", %{
      tty: tty,
      sup: sup
    } do
      assert wait_until(fn -> queried(tty, 1) end, 200)
      Tty.inject(tty, "\e]11;rgb:ff/ff/ff\a")
      refute_receive {:caps, _}, 500

      assert_receive {:caps,
                      %{colors: %{fg: nil, bg: {255, 255, 255}, palette: %{}}, scheme: nil}},
                     1000

      send(Client.input(sup), {:tty_resumed})
      assert wait_until(fn -> queried(tty, 2) end, 200)
    end

    test "a late startup DA1 keeps the window; the status sentinel ends it early", %{tty: tty} do
      assert wait_until(fn -> queried(tty, 1) end, 200)
      Tty.inject(tty, "\e[?62;22c\e]10;rgb:00/00/00\a\e[0n")
      assert_receive {:caps, %{colors: %{fg: {0, 0, 0}, bg: nil}}}, 300
    end

    test "no answer sends no caps", %{tty: tty} do
      assert wait_until(fn -> queried(tty, 1) end, 200)
      refute_receive {:caps, _}, 1200
    end
  end

  defp wait_until(f, n \\ 100) do
    case f.() do
      x when x in [nil, false] and n > 0 ->
        Process.sleep(5)
        wait_until(f, n - 1)

      x ->
        x
    end
  end
end
