defmodule DynideServer.Client.SessionCapsTest do
  # A client's `{:caps, _}` (host colours and scheme): stored per session; the foreground
  # session's also set every pane vt's colours (fake kernel).
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.Protocol
  alias DynideServer.App.{Actions, Store}
  alias DynideServer.Kernel.Fake
  alias DynideServer.Pane.{Facts, Rows}

  @size %{cols: 80, rows: 24}
  @colors %{fg: {1, 2, 3}, bg: {4, 5, 6}, palette: %{1 => {255, 0, 0}}}

  setup do
    reset()
    on_exit(&reset/0)
    session = attach()
    assert eventually(fn -> Facts.get(1) != nil end)
    :ok = Store.run({Actions, :split, [:horizontal]}, @size)
    assert eventually(fn -> Facts.get(2) != nil end)
    %{session: session}
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(DynideServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(DynideServer.Client.Supervisor, pid)

    :ets.delete(:dynide_pane_facts, :host_colors)
    :ets.delete(:dynide_pane_facts, :foreground)
    Store.reset()
  end

  defp attach do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: @size,
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, GenServer.call(Protocol.endpoint(), {:attach, info})})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, {:ok, session, _}}
    session
  end

  defp res(id), do: elem(Fake.Keeper.lookup(Rows.kernel_id(id)), 1)
  defp vt_colors(id), do: Fake.Vt.colors(res(id).vt)
  defp written(id), do: res(id).pty |> Fake.Pty.writes() |> IO.iodata_to_binary()

  defp eventually(f, n \\ 100) do
    cond do
      f.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && eventually(f, n - 1)
    end
  end

  test "the foreground session's colours and scheme reach every pane vt", %{session: s} do
    send(s, {:caps, %{colors: @colors, scheme: :dark}})
    want = %{colors: @colors, scheme: :dark}
    assert eventually(fn -> vt_colors(1) == want and vt_colors(2) == want end)
    assert Facts.host_colors() == %{colors: @colors, scheme: :dark}
    assert :sys.get_state(s).caps == %{colors: @colors, scheme: :dark}

    # a scheme-only update keeps the colours
    send(s, {:caps, %{scheme: :light}})
    assert eventually(fn -> vt_colors(2) == %{want | scheme: :light} end)
    assert :sys.get_state(s).caps == %{colors: @colors, scheme: :light}
  end

  test "a scheme change is reported to panes in mode 2031 only", %{session: s} do
    :ok = Fake.Vt.set_mode(res(1).vt, :color_scheme_report, true)
    send(s, {:caps, %{scheme: :dark}})
    assert eventually(fn -> written(1) == "\e[?997;1n" end)
    send(s, {:caps, %{scheme: :light}})
    assert eventually(fn -> written(1) == "\e[?997;1n\e[?997;2n" end)
    # unchanged: no report
    send(s, {:caps, %{colors: @colors, scheme: :light}})
    assert eventually(fn -> vt_colors(1).colors != nil end)
    :sys.get_state(s)
    assert written(1) == "\e[?997;1n\e[?997;2n"
    assert written(2) == ""
  end

  test "a background session's caps are kept but not applied", %{session: s} do
    _foreground = attach()
    send(s, {:caps, %{colors: @colors, scheme: :dark}})
    assert :sys.get_state(s).caps == %{colors: @colors, scheme: :dark}
    assert Facts.host_colors() == nil
    assert vt_colors(1) == %{colors: nil, scheme: nil}
  end

  test "becoming the foreground client re-applies the session's own colours", %{session: s} do
    b = attach()
    send(s, {:caps, %{colors: @colors, scheme: :dark}})
    assert :sys.get_state(s).caps == %{colors: @colors, scheme: :dark}
    assert vt_colors(1) == %{colors: nil, scheme: nil}

    # a slow-path input makes `s` the foreground client
    send(s, {:input, self(), 1, {:focus, true}})
    assert_receive {:ack, 1}
    want = %{colors: @colors, scheme: :dark}
    assert eventually(fn -> vt_colors(1) == want and vt_colors(2) == want end)

    # back to `b`, which has no colours: nothing changes
    send(b, {:input, self(), 1, {:focus, true}})
    assert_receive {:ack, 1}
    :sys.get_state(b)
    assert vt_colors(1) == want
  end

  test "malformed colours are ignored", %{session: s} do
    send(s, {:caps, %{colors: %{fg: {256, 0, 0}}, scheme: :dark}})
    :sys.get_state(s)
    assert Facts.host_colors() == nil
    assert vt_colors(1) == %{colors: nil, scheme: nil}
    assert Process.alive?(s)
  end
end
