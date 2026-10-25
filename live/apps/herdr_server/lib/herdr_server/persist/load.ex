defmodule HerdrServer.Persist.Load do
  @moduledoc """
  The Store's disk restore (M8), run from `App.Store.handle_continue/2` when a fresh Store
  (no carry, no mirror) starts with persistence enabled. It takes and returns the Store
  state as a plain map, as `Store.Carry` and `Store.Mirror` do.

  `Disk.read/1`, then the pure parts through `HerdrReload.Guard`: `Schema.restore/1`,
  `App.Upgrade.app/1` (before the app is adopted, as for mirror and rollback restores),
  `RestorePlan.spawns/4` and `RestorePlan.resumes/2` (with the config file read now, so
  `[session]` applies before the Store's own config load; a failure there only skips the
  resumes); `Disk.read/1` itself runs under `Guard.run/4`, so a raise there cannot
  crash-loop the Store. The spawns run through the Store's own effect handler;
  each resume write of a pane that spawned goes to the Store (`self()`) with
  `Process.send_after/3`, which writes it to the pane's queue when it fires.
  A pane closed before then drops its write; a Store crash inside the delay window loses
  the resumes still pending.

  Telemetry: `persist_restore source=disk reason=.. panes=N scrollback=K ms=T` after a
  restore (N and K count the panes that actually spawned), `persist_restore source=none
  reason=..` without a file, one `persist_error op=read reason=..` when the snapshot
  cannot be restored. A file that decodes but cannot be restored is set aside
  (`Disk.set_aside/2`) so the Writer does not overwrite the only copy; one that does not
  decode or cannot be read is set aside and logged by `Disk.read/1`. On any failure the
  app stays nil, and the first client event initialises it at that client's size.

  Before the spawns, `:persistent_term` key `#{inspect({__MODULE__, :attempt})}` holds the
  session path until the Store calls `finish/1` after its mirror flush. A Store that
  crashes in between (a file that validates but crashes the restore) finds the marker on
  restart: `crashed?/1` sets the file aside (`reason=restore_crashed`) and the Store
  starts fresh instead of re-reading the same file in a loop.
  """

  alias HerdrReload.{Guard, Telemetry}
  alias HerdrServer.App.{Store, Upgrade}
  alias HerdrServer.App.Store.Config, as: StoreConfig
  alias HerdrServer.Handoff.Link
  alias HerdrServer.Persist.{Disk, RestorePlan, Schema}

  @attempt {__MODULE__, :attempt}

  @doc "Restores the app on disk into `state` (`app: nil`), spawning through `effect`."
  @spec run(map, Disk.cfg(), (map, tuple -> map)) :: map
  def run(%{app: nil} = state, cfg, effect) do
    t0 = System.monotonic_time(:millisecond)

    case Guard.run(Disk, :read, [cfg], server: Store.reload_server()) do
      {:ok, {:ok, snap, _saved_at}} ->
        restore(state, cfg, snap, effect, t0)

      {:ok, :none} ->
        Telemetry.event(:persist_restore, source: :none, reason: fresh_reason())
        state

      # did not decode or could not be read (anything but :enoent): moved aside and logged
      {:ok, {:error, _set_aside_and_logged_by_disk}} ->
        state

      {:failed, failure} ->
        set_aside(cfg, Guard.message(failure))
        state
    end
  end

  def run(state, _cfg, _effect), do: state

  @doc """
  True when a previous Store crashed during a disk restore (the marker is set): erases the
  marker and sets the session file aside with `reason=restore_crashed`.
  """
  @spec crashed?(Disk.cfg()) :: boolean
  def crashed?(cfg) do
    case :persistent_term.get(@attempt, nil) do
      nil ->
        false

      _path ->
        :persistent_term.erase(@attempt)
        set_aside(cfg, "restore_crashed")
        true
    end
  end

  @doc "Ends a disk restore: erases the marker. Returns `state`."
  @spec finish(map) :: map
  def finish(state) do
    :persistent_term.erase(@attempt)
    state
  end

  # one persist_error line either way, even when setting the file aside raises too
  defp set_aside(cfg, reason) do
    with {:failed, _} <- Guard.run(Disk, :set_aside, [cfg, reason], server: Store.reload_server()),
         do: Telemetry.event(:persist_error, op: :read, reason: reason)
  end

  defp restore(state, cfg, snap, effect, t0) do
    case plan(cfg, snap) do
      {:ok, app, spawns, resumes} ->
        :persistent_term.put(@attempt, Disk.session_path(cfg))
        state = Enum.reduce(spawns, %{state | app: app}, &effect.(&2, &1))
        spawned = Enum.filter(spawns, fn {:spawn, id, _, _} -> state.sizes[id] end)

        for {ms, {:paste_raw, id, _} = w} <- resumes,
            state.sizes[id],
            do: Process.send_after(self(), w, ms)

        Telemetry.event(:persist_restore,
          source: :disk,
          reason: fresh_reason(),
          panes: length(spawned),
          scrollback: Enum.count(spawned, fn {:spawn, _, _, o} -> o.replay != nil end),
          ms: System.monotonic_time(:millisecond) - t0
        )

        state

      {:error, reason} ->
        set_aside(cfg, reason)
        state
    end
  end

  defp plan(cfg, snap) do
    g = [server: Store.reload_server()]

    with {:ok, {:ok, app, facts}} <- Guard.run_twice(Schema, :restore, [snap], g),
         {:ok, app} <- Guard.run_twice(Upgrade, :app, [app], g),
         sb = scrollback(cfg, Map.keys(facts)),
         {:ok, spawns} <-
           Guard.run_twice(RestorePlan, :spawns, [app, facts, sb, &File.dir?/1], g) do
      {:ok, app, spawns, resumes(app, g)}
    else
      {:ok, {:error, reason}} -> {:error, inspect(reason)}
      {:failed, reason} -> {:error, Guard.message(reason)}
    end
  end

  defp resumes(app, g) do
    case Guard.run_twice(RestorePlan, :resumes, [app, StoreConfig.load()], g) do
      {:ok, resumes} -> resumes
      {:failed, _logged_by_guard} -> []
    end
  end

  defp scrollback(cfg, ids) do
    for id <- ids, bytes = Disk.read_scrollback(cfg, id), into: %{}, do: {id, bytes}
  end

  # :fallback after the broker lost the session; nil without a broker
  defp fresh_reason, do: Link.fresh_reason() || :boot
end
