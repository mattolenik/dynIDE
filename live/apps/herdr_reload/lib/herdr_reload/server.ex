defmodule HerdrReload.Server do
  @moduledoc """
  Owns the reload history: compiles batches, loads them, and rolls them back.

  Compiles run in this process itself: it is dedicated to reloading, so app
  processes are never blocked, and callers needing a rollback during a compile
  simply wait (every call uses `:infinity`).

  After a rollback the source still holds the rolled-back code, but its beam is the
  previous one. Only a content change of that source reloads it: re-saving or touching
  the same bytes is skipped here (unchanged since its last compile) and Mix would find
  nothing to do anyway (unchanged digest).

  A public ETS table named like the server holds Guard counters, `{mod, count}`
  and `{:total, count}`, which decide whether a batch is still live.

  The optional `state_at_load` provider (a 0-arity fun or `{m, f, a}`; the
  `:state_at_load` opt, else the `config :herdr_reload, HerdrReload, state_at_load:`
  value read at each batch, which the app owning the state sets at its start) runs
  inside the Server's reload call. It must not raise, and it must not
  `GenServer.call` a process that may itself be blocked in a guarded call
  waiting on `fail/4` (that deadlocks); read an ETS mirror instead.
  """

  use GenServer

  alias HerdrReload.{Batch, Compiler, Loader, Notices, Ring}

  require Logger

  @type server :: GenServer.server()

  @doc "Starts the server; see the moduledoc and opts in `init/1`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Compiles and loads `paths` as one batch. Paths whose content is unchanged since this
  server last compiled them are skipped (`:noop`, no Mix run, when none remain).
  """
  @spec reload(server(), [Path.t()]) ::
          {:ok, Batch.t()} | :noop | {:error, list()} | {:blocked, module(), [Loader.pid_info()]}
  def reload(server \\ __MODULE__, paths), do: GenServer.call(server, {:reload, paths}, :infinity)

  @doc "Rolls back the `n` newest batches not yet rolled back, newest first."
  @spec rollback(pos_integer()) :: {:ok, [pos_integer()]}
  def rollback(n \\ 1) when is_integer(n), do: rollback(__MODULE__, n)

  @spec rollback(server(), pos_integer(), timeout()) :: {:ok, [pos_integer()]}
  def rollback(server, n, timeout \\ :infinity),
    do: GenServer.call(server, {:rollback, n}, timeout)

  @doc """
  Blames a failure on the newest live batch touching `stack_modules` and rolls it back.
  Only batches loaded at or before `failed_at` (monotonic ms, default now) are blamed: a
  failure during a compile (when Mix has deleted the modules it rebuilds) waits here for
  that compile, and must not land on the batch it then loads.
  """
  @spec fail(server(), [module()], term(), integer()) ::
          {:rolled_back, pos_integer()} | :unattributed
  def fail(server, stack_modules, reason, failed_at),
    do: GenServer.call(server, {:fail, stack_modules, reason, failed_at}, :infinity)

  @spec fail(server(), [module()], term()) :: {:rolled_back, pos_integer()} | :unattributed
  def fail(server \\ __MODULE__, stack_modules, reason),
    do: fail(server, stack_modules, reason, System.monotonic_time(:millisecond))

  @doc """
  The batch whose `state_at_load` precedes the newest rollback that had one: the
  oldest batch of that rollback with a non-nil `state_at_load`.
  """
  @spec last_rolled_back(server()) :: {:ok, pos_integer(), term()} | :none
  def last_rolled_back(server \\ __MODULE__),
    do: GenServer.call(server, :last_rolled_back, :infinity)

  @doc "Recorded batches, newest first."
  @spec batches(server(), timeout()) :: [Batch.t()]
  def batches(server \\ __MODULE__, timeout \\ :infinity),
    do: GenServer.call(server, :batches, timeout)

  @doc "Modules the promotion sync loaded at init (empty when none)."
  @spec synced(server(), timeout()) :: [module()]
  def synced(server \\ __MODULE__, timeout \\ :infinity),
    do: GenServer.call(server, :synced, timeout)

  @doc "Name of the Guard counters table."
  @spec counters_table(server()) :: atom()
  def counters_table(server), do: GenServer.call(server, :counters_table, :infinity)

  @impl true
  def init(opts) do
    compile_opts = Keyword.take(opts, [:project_dir, :app, :allowlist])

    table =
      :ets.new(opts[:name], [
        :named_table,
        :public,
        write_concurrency: true,
        decentralized_counters: true
      ])

    {:ok,
     %{
       table: table,
       compile_opts: compile_opts,
       loader_opts: [allowlist: Keyword.get(opts, :allowlist, [])],
       live_opts: Keyword.take(opts, [:exercise_n, :exercise_floor_ms]),
       state_at_load: opts[:state_at_load],
       cache: Compiler.snapshot(compile_opts),
       rejected_dir: Path.join([Compiler.build_path(compile_opts), "herdr_reload", "rejected"]),
       # batch ids restart per VM run: the stamp keeps an earlier run's rejects
       vm_stamp: System.os_time(:millisecond),
       mtimes: Compiler.source_mtimes(compile_opts),
       # path => content digest when we last compiled it
       digests: %{},
       ring: Ring.new(Keyword.get(opts, :ring_depth, 8)),
       last_rolled_back: :none,
       synced: [],
       next_id: 1
     }, {:continue, :sync_loaded}}
  end

  # Ruling 28: a promoted standby runs the code it preloaded at boot, while edits the
  # primary reloaded since then are on disk (this cache). Load those, so the cache is
  # what runs; no batch is recorded (the old code's beam is gone). NIF modules are never
  # reloaded (their library stays as loaded); a load blocked by old code is logged.
  @impl true
  def handle_continue(:sync_loaded, s) do
    stale =
      for {mod, bin} <- s.cache,
          :code.is_loaded(mod) != false,
          {:ok, {_, md5}} <- [:beam_lib.md5(bin)],
          md5 != mod.module_info(:md5),
          not nif?(bin),
          do: {mod, bin}

    errors = load_all(stale, s.loader_opts)

    for {mod, e} <- errors,
        do: Logger.warning("reload sync of #{inspect(mod)} failed: #{inspect(e)}")

    failed = Keyword.keys(errors)
    synced = for {mod, _} <- stale, mod not in failed, do: mod
    if stale != [], do: Notices.broadcast({:synced, synced}, failed: length(failed))

    {:noreply, Map.put(s, :synced, synced)}
  end

  # unreadable imports: leave it alone too
  defp nif?(bin) do
    case :beam_lib.chunks(bin, [:imports]) do
      {:ok, {_, [imports: i]}} -> {:erlang, :load_nif, 2} in i
      _ -> true
    end
  end

  @impl true
  def handle_call({:reload, paths}, _from, s) do
    # Read before Mix runs: a write during the compile then differs and compiles next time.
    digests = Map.new(paths, &{&1, digest(&1)})
    # Unchanged since we last compiled it: a duplicate event, or the event of the
    # compiler's own back-date touch, which would otherwise back-date and fire again.
    fresh = Enum.reject(paths, &(digests[&1] != nil and digests[&1] == s.digests[&1]))
    s_done = %{s | digests: Map.merge(s.digests, Map.take(digests, fresh))}

    started = System.monotonic_time(:millisecond)
    result = fresh != [] && Compiler.compile(s.cache, fresh, s.mtimes, s.compile_opts)
    compile_ms = System.monotonic_time(:millisecond) - started

    case result do
      false ->
        {:reply, :noop, s}

      {:ok, %{changed: c, removed: [], mtimes: m}} when c == %{} ->
        {:reply, :noop, %{s_done | mtimes: m}}

      {:ok, res} ->
        {batch, s} = record(res, compile_ms, %{s_done | mtimes: res.mtimes})
        {:reply, {:ok, batch}, s}

      {:error, diags, mtimes} ->
        Notices.broadcast({:compile_error, diags})
        {:reply, {:error, diags}, %{s_done | mtimes: mtimes}}

      {:blocked, _, _} = blocked ->
        {:reply, blocked, s}
    end
  end

  def handle_call({:rollback, n}, _from, s) do
    targets = s.ring |> Ring.batches() |> Enum.reject(& &1.rolled_back) |> Enum.take(n)
    s = undo(targets, :manual, s)
    {:reply, {:ok, Enum.map(targets, & &1.id)}, s}
  end

  def handle_call({:fail, stack_modules, reason, failed_at}, _from, s) do
    now = System.monotonic_time(:millisecond)
    total = count(s.table, :total)

    # only modules a guarded call has entered: the rest must not hold a batch open
    live? = fn b ->
      counters = for m <- b.modules, [{^m, c}] <- [:ets.lookup(s.table, m)], into: %{}, do: {m, c}
      b.loaded_at <= failed_at and Ring.live?(b, counters, total, now, s.live_opts)
    end

    case Ring.attribute(s.ring, stack_modules, live?) do
      nil ->
        {:reply, :unattributed, s}

      %Batch{id: id} ->
        ring = Ring.update(s.ring, id, &%{&1 | failures: &1.failures + 1})
        set = ring |> Ring.rollback_set(id) |> Enum.reject(& &1.rolled_back)
        s = undo(set, reason, %{s | ring: ring})
        {:reply, {:rolled_back, id}, s}
    end
  end

  def handle_call(:batches, _from, s), do: {:reply, Ring.batches(s.ring), s}
  def handle_call(:last_rolled_back, _from, s), do: {:reply, s.last_rolled_back, s}
  def handle_call(:synced, _from, s), do: {:reply, Map.get(s, :synced, []), s}
  def handle_call(:counters_table, _from, s), do: {:reply, s.table, s}

  defp record(res, compile_ms, s) do
    modules = Map.keys(res.changed) ++ res.removed

    state = state_at_load(s.state_at_load)
    beams = Map.merge(res.changed, Map.new(res.removed, &{&1, nil}))

    for {mod, e} <- load_all(beams, s.loader_opts),
        do: Logger.warning("reload load of #{inspect(mod)} failed: #{inspect(e)}")

    # stamped once loaded: a failure before this ran the old code (or none)
    batch = %Batch{
      id: s.next_id,
      modules: modules,
      previous_beams: res.previous,
      beam_paths: res.paths,
      state_at_load: state,
      loaded_at: System.monotonic_time(:millisecond),
      baseline: Map.new(modules, &{&1, count(s.table, &1)}),
      total_baseline: count(s.table, :total)
    }

    {ring, _evicted} = Ring.push(s.ring, batch)

    Notices.broadcast({:loaded, batch.id, modules}, compile_ms: compile_ms)
    {batch, %{s | ring: ring, next_id: s.next_id + 1, cache: apply_cache(s.cache, beams, [])}}
  end

  # `batches` newest first. Each module is loaded once, with its beam from the
  # oldest batch holding it: loading it per batch would leave the intermediate
  # code as old code, blocking the next purge while a caller still runs it.
  # Loader failures already broadcast purge_blocked; keep going for the rest.
  # A module whose load failed keeps its bad beam on disk too.
  defp undo(batches, reason, s) do
    beams = Enum.reduce(batches, %{}, &Map.merge(&2, &1.previous_beams))
    errors = load_all(beams, s.loader_opts)
    restore_disk(batches, Map.drop(beams, Keyword.keys(errors)), s)

    ring =
      Enum.reduce(batches, s.ring, fn batch, ring ->
        errs = for {m, _} = e <- errors, m in batch.modules, do: e
        reason = if errs == [], do: reason, else: {reason, errs}
        Notices.broadcast({:rolled_back, batch.id, batch.modules, reason})
        Ring.update(ring, batch.id, &%{&1 | rolled_back: true})
      end)

    last =
      case batches |> Enum.reject(&is_nil(&1.state_at_load)) |> List.last() do
        nil -> s.last_rolled_back
        b -> {:ok, b.id, b.state_at_load}
      end

    %{
      s
      | ring: ring,
        last_rolled_back: last,
        cache: apply_cache(s.cache, beams, Enum.map(errors, &elem(&1, 0)))
    }
  end

  # The bad beam moves to `rejected/<vm stamp>-<newest batch id>/`, so Mix and autoload
  # see the previous beam (or none, for a module new in the batch).
  defp restore_disk(batches, beams, s) do
    for {mod, prev} <- beams,
        %Batch{id: id, beam_paths: %{^mod => path}} when is_binary(path) <-
          [Enum.find(batches, &(mod in &1.modules))] do
      dest = Path.join([s.rejected_dir, "#{s.vm_stamp}-#{id}", Path.basename(path)])

      with {:error, e} <- swap_beam(path, dest, prev),
           do: Logger.warning("reload disk restore of #{inspect(mod)} failed: #{inspect(e)}")
    end
  end

  defp swap_beam(path, dest, prev) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- reject(path, dest),
         do: if(prev, do: File.write(path, prev), else: :ok)
  end

  # a removed module has no bad beam left on disk
  defp reject(path, dest) do
    case File.rename(path, dest) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  defp load_all(beams, opts) do
    for {mod, bin} <- beams, {:error, e} <- [Loader.load(mod, bin, opts)], do: {mod, e}
  end

  defp apply_cache(cache, beams, failed) do
    Enum.reduce(Map.drop(beams, failed), cache, fn
      {mod, nil}, acc -> Map.delete(acc, mod)
      {mod, bin}, acc -> Map.put(acc, mod, bin)
    end)
  end

  defp digest(path) do
    case File.read(path) do
      {:ok, bin} -> :erlang.md5(bin)
      {:error, _} -> nil
    end
  end

  defp count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp state_at_load(nil),
    do: state_at_load(Application.get_env(:herdr_reload, HerdrReload, [])[:state_at_load] || :none)

  defp state_at_load(:none), do: nil
  defp state_at_load(fun) when is_function(fun, 0), do: fun.()
  defp state_at_load({m, f, a}), do: apply(m, f, a)
end
