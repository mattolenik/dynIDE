defmodule HerdrServer.Persist.Load do
  @moduledoc """
  The Store's disk restore (M8), run from `App.Store.handle_continue/2` when a fresh Store
  (no carry, no mirror) starts with persistence enabled. It takes and returns the Store
  state as a plain map, as `Store.Carry` and `Store.Mirror` do.

  `Disk.read/1`, then the pure parts through `HerdrReload.Guard`: `Schema.restore/1`,
  `Schema.upgrade/1` (before the app is adopted), `RestorePlan.spawns/4`. The spawns run
  through the Store's own effect handler. Telemetry: `persist_restore source=disk
  reason=.. panes=N scrollback=K ms=T` after a restore, `persist_restore source=none
  reason=..` without a file, `persist_error op=read reason=..` when the snapshot cannot be
  restored (a file that does not decode is logged by `Disk.read/1`). On any failure the
  app stays nil, and the first client event initialises it at that client's size.
  """

  alias HerdrReload.{Guard, Telemetry}
  alias HerdrServer.App.Store
  alias HerdrServer.Persist.{Disk, RestorePlan, Schema}

  @doc "Restores the app on disk into `state` (`app: nil`), spawning through `effect`."
  @spec run(map, Disk.cfg(), (map, tuple -> map)) :: map
  def run(%{app: nil} = state, cfg, effect) do
    t0 = System.monotonic_time(:millisecond)

    case Disk.read(cfg) do
      {:ok, snap, _saved_at} ->
        case plan(cfg, snap) do
          {:ok, app, spawns} ->
            state = Enum.reduce(spawns, %{state | app: app}, &effect.(&2, &1))

            Telemetry.event(:persist_restore,
              source: :disk,
              reason: fresh_reason(),
              panes: length(spawns),
              scrollback: Enum.count(spawns, fn {:spawn, _, _, o} -> o.replay != nil end),
              ms: System.monotonic_time(:millisecond) - t0
            )

            state

          {:error, reason} ->
            Telemetry.event(:persist_error, op: :read, reason: reason)
            state
        end

      :none ->
        Telemetry.event(:persist_restore, source: :none, reason: fresh_reason())
        state

      {:error, _logged_by_disk} ->
        state
    end
  end

  def run(state, _cfg, _effect), do: state

  defp plan(cfg, snap) do
    g = [server: Store.reload_server()]

    with {:ok, {:ok, app, facts}} <- Guard.run_twice(Schema, :restore, [snap], g),
         {:ok, app} <- Guard.run_twice(Schema, :upgrade, [app], g),
         sb = scrollback(cfg, Map.keys(facts)),
         {:ok, spawns} <-
           Guard.run_twice(RestorePlan, :spawns, [app, facts, sb, &File.dir?/1], g) do
      {:ok, app, spawns}
    else
      {:ok, {:error, reason}} -> {:error, inspect(reason)}
      {:failed, reason} -> {:error, Guard.message(reason)}
    end
  end

  defp scrollback(cfg, ids) do
    for id <- ids, bytes = Disk.read_scrollback(cfg, id), into: %{}, do: {id, bytes}
  end

  # Task 6 replaces this with Handoff.Link.fresh_reason/0 (:boot or :fallback)
  defp fresh_reason, do: :boot
end
