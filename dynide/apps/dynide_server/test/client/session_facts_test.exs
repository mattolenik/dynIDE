defmodule DynideServer.Client.SessionFactsTest do
  # `{:pane_facts, id}` bursts repaint a session at most once per window (fake kernel).
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.Protocol
  alias DynideServer.App.Store
  alias DynideServer.Pane.Facts

  setup do
    reset()
    on_exit(&reset/0)
    session = attach()
    assert eventually(fn -> Facts.get(1) != nil end)
    %{session: session}
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(DynideServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(DynideServer.Client.Supervisor, pid)

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
    assert_receive {:attached, {:ok, session, _}}
    session
  end

  defp eventually(f, n \\ 100) do
    cond do
      f.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && eventually(f, n - 1)
    end
  end

  # the session's repaints are its `Store.snapshot/0` calls
  defp snapshots(session, n) do
    receive do
      {:trace, _, :receive, {:"$gen_call", {^session, _}, :snapshot}} -> snapshots(session, n + 1)
      {:trace, _, :receive, _} -> snapshots(session, n)
    after
      200 -> n
    end
  end

  test "a burst of 100 facts messages repaints once or twice", %{session: s} do
    assert eventually(fn -> :sys.get_state(s).last_scene != nil end)
    store = Process.whereis(Store)
    :erlang.trace(store, true, [:receive])
    on_exit(fn -> :erlang.trace(store, false, [:receive]) end)

    :sys.suspend(s)
    for _ <- 1..100, do: send(s, {:pane_facts, 1})
    :sys.resume(s)

    n = snapshots(s, 0)
    assert n in 1..2, "#{n} repaints"
  end

  test "facts after a quiet window repaint at once", %{session: s} do
    assert eventually(fn -> :sys.get_state(s).last_scene != nil end)
    store = Process.whereis(Store)
    :erlang.trace(store, true, [:receive])
    on_exit(fn -> :erlang.trace(store, false, [:receive]) end)

    send(s, {:pane_facts, 1})
    assert_receive {:trace, _, :receive, {:"$gen_call", {^s, _}, :snapshot}}, 100
  end
end
