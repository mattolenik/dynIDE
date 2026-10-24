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
    assert_receive {:attached, %{kind: :term, size: %{cols: 80, rows: 24}}, _session}
    %{sup: sup, tty: Client.tty(sup)}
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

  test "queries the terminal on start and consumes the replies", %{tty: tty} do
    assert Tty.written(tty) == "\e[?u\e[c"
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

  test "an intercepted key goes slow and holds the next one until acked", %{tty: tty} do
    fast([{"b", [:ctrl]}])
    Tty.inject(tty, "\x02v")
    assert_receive {:input, from, 1, {:key, %{key: "b", mods: [:ctrl]}}}
    refute_receive {:fast, _}, 50
    send(from, {:ack, 1})
    assert_receive {:fast, {:key, %{key: "v"}}}
  end

  test "a lone escape flushes after the timeout", %{tty: tty} do
    Tty.inject(tty, "\e")
    refute_receive {:input, _, _, _}, 10
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
