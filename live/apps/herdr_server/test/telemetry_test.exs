defmodule HerdrServer.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HerdrServer.App.Store
  alias HerdrServer.Handoff.Notice

  test "a handoff notice logs a handoff line" do
    log =
      capture_log(fn ->
        Notice.broadcast({:handoff, %{phase: :adopted, gen: 2, panes: [1, 2, 3]}})
      end)

    assert log =~ ~r/herdr-event handoff ts=\d{13} phase=adopted gen=2 panes=3/
  end

  test "start and stop log vm_start and vm_stop" do
    log = capture_log(fn -> HerdrServer.Application.announce_start() end)
    assert log =~ "herdr-live started"
    assert log =~ ~r/herdr-event vm_start ts=\d{13} gen=\d+ role=primary adopt=fresh/

    log = capture_log(fn -> HerdrServer.Application.stop(nil) end)
    assert log =~ "herdr-live stopped"
    assert log =~ ~r/herdr-event vm_stop ts=\d{13} gen=\d+/
  end

  test "a Store restarting from the mirror logs a crash line" do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    # the mirror is debounced
    wait_until(fn -> HerdrServer.Mirror.app() != nil end)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
        {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)
      end)

    assert log =~ ~r/herdr-event crash ts=\d{13} proc=store reason=restart action=restored/
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
