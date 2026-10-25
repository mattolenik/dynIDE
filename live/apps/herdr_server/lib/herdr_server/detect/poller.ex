defmodule HerdrServer.Detect.Poller do
  @moduledoc """
  Drives agent detection over every pane of the app. Thin: the logic is in
  `Detect.Tracker`, `Identify`, `Engine` and `Manifests`, each called through
  `HerdrReload.Guard.run_twice/4` (a failure skips that pane this tick).

  Each tick (every 300 ms, sooner when a tracker asks via `Tracker.next_ms/2`)
  drops trackers of panes no longer in the app (and their `Pane.Facts.agent/1`
  row), then walks the panes in id order starting after the last scanned one:
  foreground pgid -> `Tracker.pgid`; on a probe (at most 4 per tick; one over
  the budget stays due) the foreground job -> `Identify.agent` -> `Tracker.job`; then, when `Tracker.scan?` and fewer than 4
  panes were scanned this tick, the detection source (the bottom `rows` rows of
  the screen, never the viewport) -> `Engine.detect` -> `Tracker.screen`.
  Effects go to the Store (`{:pane_agent, id, label}`, `{:agent_state, id,
  state}`); the pane's agent facts row is rewritten when it changes. This is the
  only writer of that row.

  One `detect_tick` telemetry line per 10 s window with any scan or probe
  (`scans`, `probes`, `max_us`, `p95_us` of tick work).

  `report/2`, `release/3` and `detect_now/1` answer `{:error, :not_found}` for a
  pane not in the app and `{:error, :failed}` when a guarded call or the read fails.
  """
  use GenServer

  require Logger

  alias HerdrReload.{Guard, Telemetry}
  alias HerdrServer.App.Store
  alias HerdrServer.Detect.{Engine, Identify, Manifests, Tracker}
  alias HerdrServer.{Kernel, Mirror}
  alias HerdrServer.Pane.{Facts, Rows}

  @interval_ms 300
  @scan_budget 4
  @probe_budget 4
  @window_ms 10_000

  defstruct trackers: %{},
            cursor: nil,
            forced: %{},
            grace_ms: 3_000,
            interval_ms: @interval_ms,
            window_ms: @window_ms,
            engine: Engine,
            timer: nil,
            last: %{scans: 0, probes: 0, us: 0},
            window: nil,
            warned: false

  @doc """
  Opts: `name` (default `#{inspect(__MODULE__)}`), `grace_ms` (tracker grace),
  `interval_ms` (tick period), `window_ms` (telemetry window) and `engine` (the
  detection module, a test seam).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Applies a hook report (`%{source, agent, state, seq}`) to pane `id`."
  @spec report(pos_integer, map, GenServer.server()) :: :ok | {:error, :not_found | :failed}
  def report(id, hook, server \\ __MODULE__), do: GenServer.call(server, {:report, id, hook})

  @doc "Drops pane `id`'s hook if it came from `source` for `agent`."
  @spec release(pos_integer, binary, binary, GenServer.server()) ::
          :ok | {:error, :not_found | :failed}
  def release(id, source, agent, server \\ __MODULE__),
    do: GenServer.call(server, {:release, id, source, agent})

  @doc """
  Reads pane `id`'s detection source now: the tracked agent, its manifest entry
  and the engine input (`agent.explain` runs the engine on it).
  """
  @spec detect_now(pos_integer, GenServer.server()) ::
          {:ok, %{entry: Manifests.entry() | nil, input: map, agent: binary | nil}}
          | {:error, :not_found | :failed}
  def detect_now(id, server \\ __MODULE__), do: GenServer.call(server, {:detect_now, id})

  @doc """
  Bench and test hook only: pane `id` is identified as `label` on every process
  probe, whatever its foreground job.
  """
  @spec force_agent(pos_integer, binary, GenServer.server()) :: :ok
  def force_agent(id, label, server \\ __MODULE__),
    do: GenServer.call(server, {:force_agent, id, label})

  @impl true
  def init(opts) do
    state =
      struct(%__MODULE__{}, Keyword.take(opts, [:grace_ms, :interval_ms, :window_ms, :engine]))

    # rows left by a previous poller: the first tick drops those of panes now gone; the
    # rest resume their label and state, so a stale label is cleared by the miss rule
    trackers = Map.new(Facts.agent_ids(), &{&1, resumed(state, Facts.agent(&1))})
    state = %{state | trackers: trackers, window: window(now())}
    {:ok, schedule(state, state.interval_ms)}
  end

  @impl true
  def handle_call({:report, id, hook}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    hooked(state, id, :report, [hook])
  end

  def handle_call({:release, id, source, agent}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    hooked(state, id, :release, [source, agent])
  end

  def handle_call({:detect_now, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    t = tracker(state, id)

    with {:pane, true} <- {:pane, id in pane_ids()},
         {:ok, %{vt: vt}} <- resources(id),
         {:ok, osc} <- pure(Tracker, :osc_input, [t, osc(id)]),
         {:ok, entry} <- entry(t.agent),
         {:ok, input} <- input(vt, osc) do
      {:reply, {:ok, %{entry: entry, input: input, agent: t.agent}}, state}
    else
      {:pane, false} -> {:reply, {:error, :not_found}, state}
      _ -> {:reply, {:error, :failed}, state}
    end
  end

  def handle_call({:force_agent, id, label}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, put_in(state.forced[id], label)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = Map.merge(%__MODULE__{}, state)
    t0 = System.monotonic_time(:microsecond)
    now = now()
    ids = pane_ids()
    state = drop_gone(state, ids)

    {state, acc} =
      ids
      |> rotate(state.cursor)
      |> Enum.reduce({state, %{scans: 0, probes: 0, next: nil}}, &poll(&1, now, &2))

    us = System.monotonic_time(:microsecond) - t0
    last = %{scans: acc.scans, probes: acc.probes, us: us}
    state = %{state | last: last} |> account(last, now)
    {:noreply, schedule(state, min(acc.next || state.interval_ms, state.interval_ms))}
  end

  def handle_info(_msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  # -- tick -------------------------------------------------------------------

  defp poll(id, now, {state, acc}) do
    with {:ok, %{vt: vt, pty: pty}} <- resources(id),
         {:ok, t, effects, acc1} <- step(state, id, vt, pty, now, acc) do
      state = apply_effects(state, id, t, effects, now)
      # the round robin resumes after the last pane scanned
      state = if acc1.scans > acc.scans, do: %{state | cursor: id}, else: state
      {state, %{acc1 | next: next_ms(t, now, acc1.next)}}
    else
      _ -> {state, acc}
    end
  end

  defp next_ms(t, now, next) do
    case pure(Tracker, :next_ms, [t, now]) do
      {:ok, ms} when is_integer(ms) -> min(ms, next || ms)
      _ -> next
    end
  end

  defp step(state, id, vt, pty, now, acc) do
    t = tracker(state, id)
    pgid = kernel(fn -> Kernel.pty().foreground_pgid(pty) end, nil)
    osc = osc(id)
    probe = %{id: id, pty: pty, now: now, osc: osc}

    with {:ok, {t1, probe?}} <- pure(Tracker, :pgid, [t, pgid, now]),
         {:ok, t, e1, acc} <- probe(state, probe, t, t1, probe?, acc),
         activity = kernel(fn -> Kernel.pty().activity(pty) end, nil),
         {:ok, scan?} <- pure(Tracker, :scan?, [t, activity, now]),
         {:ok, t, e2, acc} <-
           scan(state, t, vt, scan? and acc.scans < @scan_budget, activity, now, osc, acc) do
      {:ok, t, e1 ++ e2, acc}
    end
  end

  defp probe(_state, _p, _t0, t, false, acc), do: {:ok, t, [], acc}

  # over budget: keep the tracker from before `Tracker.pgid`, so the probe stays due
  # ponytail: shares the scan cursor; a starved prober would need its own cursor
  defp probe(_state, _p, t0, _t, true, %{probes: n} = acc) when n >= @probe_budget,
    do: {:ok, t0, [], acc}

  defp probe(state, p, _t0, t, true, acc) do
    job = kernel(fn -> Kernel.pty().foreground_job(p.pty) end, nil)

    with {:ok, agent} <- identify(state.forced[p.id], job),
         {:ok, {t, effects}} <-
           pure(Tracker, :job, [t, agent, match?(%{shell: true}, job), p.now, p.osc]) do
      {:ok, t, effects, %{acc | probes: acc.probes + 1}}
    end
  end

  defp identify(_forced, nil), do: {:ok, nil}
  defp identify(nil, job), do: pure(Identify, :agent, [job])
  defp identify(label, job), do: {:ok, {label, job.pgid}}

  defp scan(_state, t, _vt, false, _activity, _now, _osc, acc), do: {:ok, t, [], acc}

  # a failed read or detection still spends the budget (and moves the round robin
  # past the pane); the tracker keeps this tick's probe
  defp scan(state, t, vt, true, activity, now, osc, acc) do
    acc = %{acc | scans: acc.scans + 1}

    with {:ok, detection} <- detection(state, t, vt, osc),
         {:ok, {t, effects}} <- pure(Tracker, :screen, [t, detection, activity, now]) do
      {:ok, t, effects, acc}
    else
      _ -> {:ok, t, [], acc}
    end
  end

  # an exited agent's shell is idle: no read, no engine
  defp detection(_state, %Tracker{exited: true}, _vt, _osc), do: {:ok, :exited}

  defp detection(state, t, vt, osc) do
    with {:ok, osc} <- pure(Tracker, :osc_input, [t, osc]),
         {:ok, entry} <- entry(t.agent),
         {:ok, input} <- input(vt, osc) do
      pure(state.engine, :detect, [entry, input])
    end
  end

  defp entry(nil), do: {:ok, nil}
  defp entry(label), do: pure(Manifests, :get, [label])

  defp rotate(ids, nil), do: ids

  defp rotate(ids, last) do
    {later, rest} = Enum.split_with(ids, &(&1 > last))
    later ++ rest
  end

  defp drop_gone(state, ids) do
    keep = MapSet.new(ids)
    {gone, kept} = Map.split_with(state.trackers, fn {id, _} -> not MapSet.member?(keep, id) end)
    Enum.each(gone, fn {id, _} -> Facts.delete_agent(id) end)
    %{state | trackers: kept}
  end

  # -- effects and facts ------------------------------------------------------

  defp hooked(state, id, fun, args) do
    if id in pane_ids() do
      case pure(Tracker, fun, [tracker(state, id) | args]) do
        {:ok, {t, effects}} -> {:reply, :ok, apply_effects(state, id, t, effects, now())}
        {:failed, _} -> {:reply, {:error, :failed}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  defp apply_effects(state, id, t, effects, now) do
    state = Enum.reduce(effects, state, &effect(&2, id, &1))

    with {:ok, facts} <- pure(Tracker, :facts, [t]) do
      if Map.delete(Facts.agent(id) || %{}, :updated_ms) != facts,
        do: Facts.put_agent(id, Map.put(facts, :updated_ms, now))
    end

    put_in(state.trackers[id], t)
  end

  defp effect(state, id, {:agent, label}),
    do: tap(state, fn _ -> Store.event_async({:pane_agent, id, label}) end)

  defp effect(state, id, {:state, s}),
    do: tap(state, fn _ -> Store.event_async({:agent_state, id, s}) end)

  # an edited Tracker returning a shape this poller does not know: ignored, logged once
  defp effect(%{warned: true} = state, _id, _effect), do: state

  defp effect(state, id, effect) do
    Logger.warning("detect: ignoring unknown tracker effect #{inspect(effect)} for pane #{id}")
    %{state | warned: true}
  end

  # -- telemetry --------------------------------------------------------------

  defp window(now), do: %{started: now, scans: 0, probes: 0, us: []}

  defp account(state, last, now) do
    w = state.window || window(now)
    w = %{w | scans: w.scans + last.scans, probes: w.probes + last.probes, us: [last.us | w.us]}

    cond do
      now - w.started < state.window_ms -> %{state | window: w}
      # an idle window logs nothing
      w.scans == 0 and w.probes == 0 -> %{state | window: window(now)}
      true -> emit(state, w, now)
    end
  end

  defp emit(state, w, now) do
    sorted = Enum.sort(w.us)
    p95 = Enum.at(sorted, min(length(sorted) - 1, div(length(sorted) * 95, 100)))

    Telemetry.event(:detect_tick,
      scans: w.scans,
      probes: w.probes,
      max_us: List.last(sorted),
      p95_us: p95
    )

    %{state | window: window(now)}
  end

  # -- reads ------------------------------------------------------------------

  defp input(vt, {title, progress}) do
    case source(Kernel.vt(), vt) do
      nil -> :error
      text -> {:ok, %{screen: text, osc_title: title, osc_progress: progress}}
    end
  end

  @doc """
  The detection source of `vt` (through vt module `mod`): its bottom `rows` screen
  rows in `scrollbar.total` coordinates, wherever the viewport is; nil when unreadable.
  """
  @spec source(module, term) :: binary | nil
  def source(mod, vt) do
    case kernel(fn -> {mod.scrollbar(vt), mod.size(vt)} end, nil) do
      {%{total: total}, {_cols, rows}} when total > 0 ->
        kernel(fn -> mod.read_text(vt, {:rows, max(total - rows, 0)..(total - 1)}) end, nil)

      _ ->
        nil
    end
  end

  defp osc(id) do
    facts = Facts.get(id) || %{}
    {Map.get(facts, :title) || "", Map.get(facts, :progress) || ""}
  end

  defp resumed(state, row) do
    t = Tracker.new(grace_ms: state.grace_ms)
    if row, do: %{t | agent: row.agent, state: row.state}, else: t
  end

  defp tracker(state, id),
    do: Map.get_lazy(state.trackers, id, fn -> Tracker.new(grace_ms: state.grace_ms) end)

  defp pane_ids do
    case Mirror.app() do
      %{session: %{panes: panes}} -> panes |> Map.keys() |> Enum.sort()
      _ -> []
    end
  end

  defp resources(id) do
    case Rows.kernel_id(id) do
      nil -> :error
      kid -> Kernel.keeper().lookup(kid)
    end
  end

  # the NIFs raise ArgumentError/ErlangError (a closed resource): the pane is skipped
  defp kernel(fun, default) do
    fun.()
  rescue
    e in [ArgumentError, ErlangError] ->
      Logger.debug("detect: kernel call failed: #{Exception.message(e)}")
      default
  end

  defp pure(mod, fun, args), do: Guard.run_twice(mod, fun, args, server: Store.reload_server())

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, ms)}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
