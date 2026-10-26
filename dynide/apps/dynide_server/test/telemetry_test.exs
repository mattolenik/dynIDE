defmodule DynideServer.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DynideServer.App.Store
  alias DynideServer.Handoff.{Link, Notice}
  alias DynideServer.Kernel.Fake.Keeper

  test "a handoff notice logs a handoff line" do
    log =
      capture_log(fn ->
        Notice.broadcast({:handoff, %{phase: :adopted, gen: 2, panes: [1, 2, 3]}})
      end)

    assert log =~ ~r/dynide-event handoff ts=\d{13} phase=adopted gen=2 panes=3/
  end

  test "start and stop log vm_start and vm_stop" do
    log = capture_log(fn -> DynideServer.Application.announce_start() end)
    assert log =~ "dynide started"
    assert log =~ ~r/dynide-event vm_start ts=\d{13} gen=\d+ role=primary adopt=fresh/

    log = capture_log(fn -> DynideServer.Application.stop(nil) end)
    assert log =~ "dynide stopped"
    assert log =~ ~r/dynide-event vm_stop ts=\d{13} gen=\d+/
  end

  test "a Store restarting from the mirror logs a crash line" do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    # the mirror is debounced
    wait_until(fn -> DynideServer.Mirror.app() != nil end)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(DynideServer.Supervisor, Store)
        {:ok, _} = Supervisor.restart_child(DynideServer.Supervisor, Store)
      end)

    assert log =~ ~r/dynide-event crash ts=\d{13} proc=store reason=restart action=restored/
  end

  describe "session_lost" do
    setup do
      Store.reset()
      on_exit(&Store.reset/0)
    end

    test "a fresh Store start that closes live panes logs session_lost" do
      :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
      wait_until(fn -> DynideServer.Mirror.app() != nil end)
      for k <- [:session, :focus, :ui], do: DynideServer.Mirror.delete({:app, k})

      log = capture_log(&restart_store/0)

      assert log =~
               ~r/dynide-event session_lost ts=\d{13} proc=store reason=fresh_restart panes=1/

      assert Keeper.ids() == []
    end

    test "a fresh Store start with no panes logs nothing" do
      log = capture_log(&restart_store/0)
      refute log =~ "session_lost"
    end

    test "a mirrored app that fails to reconcile logs session_lost" do
      :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
      wait_until(fn -> DynideServer.Mirror.app() != nil end)
      # a session Reconcile cannot read: run_twice fails, the Store closes everything
      DynideServer.Mirror.put({:app, :session}, %{bogus: true})

      log = capture_log(&restart_store/0)

      assert log =~
               ~r/dynide-event session_lost ts=\d{13} proc=store reason=reconcile_failed panes=1/
    end

    test "an unusable carried app beside adopted panes logs session_lost" do
      {:ok, kid} = Keeper.open(spec())
      blob = :erlang.term_to_binary(%{v: 1, app: %{session: %{}}, kernel_ids: [{1, kid}]})
      :ok = Link.put_adopted_for_test([{"app/store", blob, []}])

      on_exit(fn ->
        if pid = Process.whereis(Link), do: GenServer.stop(pid)
      end)

      log = capture_log(&restart_store/0)

      assert log =~
               ~r/dynide-event session_lost ts=\d{13} proc=store reason=carry_unusable panes=1/
    end
  end

  # not a kill: the supervisor's restart intensity is shared with other tests
  defp restart_store do
    :ok = Supervisor.terminate_child(DynideServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(DynideServer.Supervisor, Store)
  end

  defp spec,
    do: %{
      cmd: "sh",
      args: [],
      env: [],
      cwd: nil,
      cols: 10,
      rows: 5,
      max_scrollback: 0,
      subscriber: nil
    }

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
