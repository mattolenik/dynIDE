defmodule HerdrServer.Reload.Server do
  @moduledoc """
  Owns the reload history: compiles batches, loads them, and rolls them back.

  Compiles run in this process itself: it is dedicated to reloading, so app
  processes are never blocked, and callers needing a rollback during a compile
  simply wait (every call uses `:infinity`).

  A public ETS table named like the server holds Guard counters, `{mod, count}`
  and `{:total, count}`, which decide whether a batch is still live.
  """

  use GenServer

  alias HerdrServer.Reload.{Batch, Compiler, Loader, Notices, Ring}

  @type server :: GenServer.server()

  @doc "Starts the server; see the moduledoc and opts in `init/1`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "Compiles and loads `paths` as one batch."
  @spec reload(server(), [Path.t()]) ::
          {:ok, Batch.t()} | :noop | {:error, list()} | {:blocked, module(), [Loader.pid_info()]}
  def reload(server \\ __MODULE__, paths), do: GenServer.call(server, {:reload, paths}, :infinity)

  @doc "Rolls back the `n` newest batches not yet rolled back, newest first."
  @spec rollback(pos_integer()) :: {:ok, [pos_integer()]}
  def rollback(n \\ 1) when is_integer(n), do: rollback(__MODULE__, n)

  @spec rollback(server(), pos_integer()) :: {:ok, [pos_integer()]}
  def rollback(server, n),
    do: GenServer.call(server, {:rollback, n}, :infinity)

  @doc "Blames a failure on the newest live batch touching `stack_modules` and rolls it back."
  @spec fail(server(), [module()], term()) :: {:rolled_back, pos_integer()} | :unattributed
  def fail(server \\ __MODULE__, stack_modules, reason),
    do: GenServer.call(server, {:fail, stack_modules, reason}, :infinity)

  @doc "Recorded batches, newest first."
  @spec batches(server()) :: [Batch.t()]
  def batches(server \\ __MODULE__), do: GenServer.call(server, :batches, :infinity)

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
       mtimes: %{},
       ring: Ring.new(Keyword.get(opts, :ring_depth, 8)),
       next_id: 1
     }}
  end

  @impl true
  def handle_call({:reload, paths}, _from, s) do
    case Compiler.compile(s.cache, paths, s.mtimes, s.compile_opts) do
      {:ok, %{changed: c, removed: [], mtimes: m}} when c == %{} ->
        {:reply, :noop, %{s | mtimes: m}}

      {:ok, res} ->
        {batch, s} = record(res, %{s | mtimes: res.mtimes})
        {:reply, {:ok, batch}, s}

      {:error, diags, mtimes} ->
        Notices.broadcast({:compile_error, diags})
        {:reply, {:error, diags}, %{s | mtimes: mtimes}}

      {:blocked, _, _} = blocked ->
        {:reply, blocked, s}
    end
  end

  def handle_call({:rollback, n}, _from, s) do
    targets = s.ring |> Ring.batches() |> Enum.reject(& &1.rolled_back) |> Enum.take(n)
    s = Enum.reduce(targets, s, &undo(&1, :manual, &2))
    {:reply, {:ok, Enum.map(targets, & &1.id)}, s}
  end

  def handle_call({:fail, stack_modules, reason}, _from, s) do
    now = System.monotonic_time(:millisecond)
    total = count(s.table, :total)

    live? = fn b ->
      counters = Map.new(b.modules, &{&1, count(s.table, &1)})
      Ring.live?(b, counters, total, now, s.live_opts)
    end

    case Ring.attribute(s.ring, stack_modules, live?) do
      nil ->
        {:reply, :unattributed, s}

      %Batch{id: id} ->
        ring = Ring.update(s.ring, id, &%{&1 | failures: &1.failures + 1})
        set = ring |> Ring.rollback_set(id) |> Enum.reject(& &1.rolled_back)
        s = Enum.reduce(set, %{s | ring: ring}, &undo(&1, reason, &2))
        {:reply, {:rolled_back, id}, s}
    end
  end

  def handle_call(:batches, _from, s), do: {:reply, Ring.batches(s.ring), s}
  def handle_call(:counters_table, _from, s), do: {:reply, s.table, s}

  defp record(res, s) do
    modules = Map.keys(res.changed) ++ res.removed

    batch = %Batch{
      id: s.next_id,
      modules: modules,
      previous_beams: res.previous,
      state_at_load: state_at_load(s.state_at_load),
      loaded_at: System.monotonic_time(:millisecond),
      baseline: Map.new(modules, &{&1, count(s.table, &1)}),
      total_baseline: count(s.table, :total)
    }

    {ring, _evicted} = Ring.push(s.ring, batch)
    beams = Map.merge(res.changed, Map.new(res.removed, &{&1, nil}))
    _errors = load_all(beams, s.loader_opts)
    Notices.broadcast({:loaded, batch.id, modules})
    {batch, %{s | ring: ring, next_id: s.next_id + 1, cache: apply_cache(s.cache, beams, [])}}
  end

  # Loader failures already broadcast purge_blocked; keep going for the rest.
  defp undo(batch, reason, s) do
    errors = load_all(batch.previous_beams, s.loader_opts)
    failed = Enum.map(errors, &elem(&1, 0))
    reason = if errors == [], do: reason, else: {reason, errors}
    Notices.broadcast({:rolled_back, batch.id, batch.modules, reason})
    ring = Ring.update(s.ring, batch.id, &%{&1 | rolled_back: true})
    %{s | ring: ring, cache: apply_cache(s.cache, batch.previous_beams, failed)}
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

  defp count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp state_at_load(nil), do: nil
  defp state_at_load(fun) when is_function(fun, 0), do: fun.()
  defp state_at_load({m, f, a}), do: apply(m, f, a)
end
