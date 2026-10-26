defmodule DynideServer.Detect.Tracker do
  @moduledoc """
  Per-pane agent tracker: presence, probe cadence, screen publish rules and
  hook precedence.

  Pure; every function takes `now` in monotonic milliseconds. Ports herdr's
  `AgentDetectionPresence` and `should_probe_foreground_job` (src/pane.rs),
  `decide_screen_detection_publish` and `PendingIdleConfirmation`
  (src/pane/agent_detection.rs), and a simplified hook authority
  (src/terminal/state.rs). Effects are `{:agent, label | nil}` and
  `{:state, state}`; a state effect is emitted only when `effective/1` changes
  (never on a clear, whose `{:agent, nil}` drops the state).
  """

  alias DynideServer.Detect.Engine.Detection

  @miss_confirmations 6
  @recheck_identified 5_000
  @acquisition_window 8_000
  @fast_window 1_500
  @fast_recheck 500
  @slow_recheck 2_000
  @pending_idle_confirmations 3
  @pending_idle_cap 700
  @pending_idle_recheck 100
  @stable_refresh 800
  @no_visible %{idle: false, blocker: false, working: false}

  defstruct agent: nil,
            agent_pid: nil,
            pgid: nil,
            misses: 0,
            state: :unknown,
            visible: @no_visible,
            pending_idle: nil,
            grace_until: nil,
            grace_ms: 3_000,
            last_refresh: nil,
            scanned: nil,
            osc_stale: nil,
            hook: nil,
            last_probe: nil,
            acquired_at: nil,
            exited: false,
            exit_reported: false

  @type state :: :idle | :working | :blocked | :unknown
  @type effect :: {:agent, binary | nil} | {:state, state}
  @type osc :: {binary, binary}
  @type hook :: %{source: binary, agent: binary, state: state, seq: integer | nil}
  @type t :: %__MODULE__{}

  @spec new(keyword) :: t
  def new(opts \\ []), do: %__MODULE__{grace_ms: Keyword.get(opts, :grace_ms, 3_000)}

  @doc "Records the foreground pgid; returns whether a process probe is due."
  @spec pgid(t, pos_integer | nil, integer) :: {t, boolean}
  def pgid(%__MODULE__{pgid: old} = t, pgid, now) when pgid != old,
    do: {%{t | pgid: pgid, acquired_at: now, last_probe: now}, true}

  def pgid(t, _pgid, now) do
    if probe_due?(t, now), do: {%{t | last_probe: now}, true}, else: {t, false}
  end

  defp probe_due?(t, now) do
    elapsed = if t.last_probe, do: now - t.last_probe, else: :infinity
    age = t.acquired_at && now - t.acquired_at
    interval = if age && age <= @fast_window, do: @fast_recheck, else: @slow_recheck

    (age != nil and age <= @acquisition_window and elapsed >= interval) or
      (t.agent != nil and elapsed >= @recheck_identified)
  end

  @doc "Applies one process probe (`Identify.agent/1` output)."
  @spec job(t, {binary, pos_integer} | nil, boolean, integer, osc) :: {t, [effect]}
  def job(%__MODULE__{agent: label} = t, {label, pid}, _shell?, _now, osc),
    do:
      {%{
         t
         | agent_pid: pid,
           misses: 0,
           exited: false,
           exit_reported: false,
           osc_stale: unstale(t.osc_stale, osc)
       }, []}

  def job(t, {label, pid}, _shell?, now, osc) do
    t1 = %{
      t
      | agent: label,
        agent_pid: pid,
        misses: 0,
        exited: false,
        exit_reported: false,
        state: :unknown,
        visible: @no_visible,
        pending_idle: nil,
        scanned: nil,
        last_refresh: nil,
        grace_until: now + t.grace_ms,
        # herdr clear_osc_evidence_for_agent_transition: first acquisition keeps OSC.
        osc_stale: if(t.agent, do: osc),
        hook: if(t.hook && t.hook.agent == label, do: t.hook)
    }

    publish(t, t1, [{:agent, label}])
  end

  def job(%__MODULE__{agent: nil} = t, nil, _shell?, _now, _osc), do: {%{t | misses: 0}, []}

  # A hook-adopted agent has no process to miss; only a shell prompt counts
  # (herdr report_self_reported_agent_shell_return).
  def job(%__MODULE__{agent_pid: nil} = t, nil, false, _now, _osc), do: {t, []}

  def job(t, nil, shell?, _now, _osc) do
    t1 = %{t | misses: t.misses + 1, exited: t.exited or shell?}

    if t1.misses < @miss_confirmations do
      {t1, []}
    else
      cleared = %{
        t1
        | agent: nil,
          agent_pid: nil,
          misses: 0,
          exited: false,
          exit_reported: false,
          state: :unknown,
          visible: @no_visible,
          pending_idle: nil,
          grace_until: nil,
          osc_stale: nil,
          hook: nil
      }

      # the label effect alone: `{:pane_agent, id, nil}` clears the published state too,
      # so a state effect would be a second status event
      {cleared, [{:agent, nil}]}
    end
  end

  defp unstale(nil, _osc), do: nil

  defp unstale({st, sp}, {title, progress}) do
    case {if(st == title, do: st), if(sp == progress, do: sp)} do
      {nil, nil} -> nil
      stale -> stale
    end
  end

  @doc """
  Whether the screen should be scanned now.

  An agent exit not yet applied by `screen/4` is scanned at once, even in
  grace. Otherwise unchanged activity skips the scan in every state, not only
  idle: activity is the kernel's PTY byte counter, so OSC updates bump it too.
  """
  @spec scan?(t, term, integer) :: boolean
  def scan?(%__MODULE__{agent: nil}, _activity, _now), do: false
  def scan?(%__MODULE__{exited: true, exit_reported: false}, _activity, _now), do: true

  def scan?(t, activity, now) do
    not (t.grace_until != nil and now < t.grace_until) and
      (t.pending_idle != nil or activity != t.scanned or refresh_due?(t, now))
  end

  defp refresh_due?(t, now),
    do: t.visible.blocker and (t.last_refresh == nil or now - t.last_refresh >= @stable_refresh)

  @doc "OSC title and progress for detection, blanking values left by the previous agent."
  @spec osc_input(t, osc) :: osc
  def osc_input(%__MODULE__{osc_stale: {st, sp}}, {title, progress}),
    do: {if(title == st, do: "", else: title), if(progress == sp, do: "", else: progress)}

  def osc_input(_t, osc), do: osc

  @doc "Applies one screen detection, or `:exited` when the agent's shell returned."
  @spec screen(t, Detection.t() | :exited, term, integer) :: {t, [effect]}
  # herdr clears the exited agent's hook authority (with its seq) and the grace.
  def screen(t, :exited, activity, now) do
    hook = if t.hook && t.hook.agent != t.agent, do: t.hook
    t1 = %{t | hook: hook, grace_until: nil, exit_reported: true}
    {t2, _} = apply_screen(t1, %Detection{state: :idle, visible_idle: true}, true, activity, now)
    publish(t, t2, [])
  end

  def screen(t, %Detection{skip_state_update: true}, activity, _now),
    do: {%{t | scanned: activity}, []}

  def screen(t, %Detection{} = d, activity, now), do: apply_screen(t, d, false, activity, now)

  defp apply_screen(t, d, exited?, activity, now) do
    visible = visible(d)
    t = %{t | scanned: activity}
    plain_idle? = t.state == :working and d.state == :idle and not visible.idle and not exited?

    case hold(plain_idle?, t.pending_idle, now) do
      {:hold, pending} ->
        {%{t | pending_idle: pending}, []}

      :release ->
        refresh = if visible.blocker, do: now, else: t.last_refresh
        t1 = %{t | pending_idle: nil, state: d.state, visible: visible, last_refresh: refresh}
        publish(t, t1, [])
    end
  end

  defp visible(d) do
    %{
      idle: d.visible_idle and d.state == :idle,
      blocker: d.visible_blocker and d.state == :blocked,
      working: d.visible_working and d.state == :working
    }
  end

  defp hold(false, _pending, _now), do: :release
  defp hold(true, nil, now), do: {:hold, {now, 0}}
  defp hold(true, {started, _}, now) when now - started >= @pending_idle_cap, do: :release
  defp hold(true, {_, c}, _now) when c + 1 >= @pending_idle_confirmations, do: :release
  defp hold(true, {started, c}, _now), do: {:hold, {started, c + 1}}

  @doc "Applies a hook report."
  @spec report(t, hook) :: {t, [effect]}
  def report(%__MODULE__{agent: a} = t, %{agent: agent}) when a != nil and a != agent,
    do: {t, []}

  # herdr's `hook_report_is_newer`: after a numbered report from a source, only a
  # higher number from it counts (an unnumbered one is stale)
  def report(%__MODULE__{hook: %{source: s, seq: last}} = t, %{source: s, seq: seq})
      when is_integer(last) and (is_nil(seq) or seq <= last),
      do: {t, []}

  def report(t, %{agent: agent} = hook) do
    hook = Map.take(hook, [:source, :agent, :state, :seq])

    if t.agent,
      do: publish(t, %{t | hook: hook}, []),
      else: publish(t, %{t | hook: hook, agent: agent}, [{:agent, agent}])
  end

  @doc "Drops the hook if it came from `source` for `agent`."
  @spec release(t, binary, binary) :: {t, [effect]}
  def release(%__MODULE__{hook: %{source: s, agent: a}} = t, s, a),
    do: publish(t, %{t | hook: nil}, [])

  def release(t, _source, _agent), do: {t, []}

  @doc """
  The pane's agent facts (`Pane.Facts.agent/1` without `updated_ms`); `skipped`
  is herdr's `screen_detection_skipped` (a full-lifecycle hook holds the state,
  `full_lifecycle?/2`).
  """
  @spec facts(t) :: map
  def facts(t) do
    %{
      agent: t.agent,
      state: effective(t),
      visible: t.visible,
      hook_source: if(is_map(t.hook), do: t.hook[:source]),
      skipped: is_map(t.hook) and full_lifecycle?(t.hook[:source], t.hook[:agent])
    }
  end

  @full_lifecycle [
    {"herdr:pi", "pi"},
    {"herdr:omp", "omp"},
    {"herdr:mastracode", "mastracode"},
    {"herdr:opencode", "opencode"},
    {"herdr:kilo", "kilo"},
    {"herdr:kimi", "kimi"}
  ]

  @doc """
  herdr's `full_lifecycle_hook_authority` (detect/mod.rs): the integrations whose
  hooks report every state, so the screen is not evaluated while they hold it.
  """
  @spec full_lifecycle?(term, term) :: boolean
  def full_lifecycle?(source, agent), do: {source, agent} in @full_lifecycle

  @doc "Published state: the hook's, unless a visible blocker overrides it."
  @spec effective(t) :: state
  def effective(%__MODULE__{hook: %{state: hs}, visible: %{blocker: vb}})
      when not vb or hs == :blocked,
      do: hs

  def effective(t), do: t.state

  @doc "Milliseconds until the tracker wants another scan, or nil."
  @spec next_ms(t, integer) :: pos_integer | nil
  def next_ms(%__MODULE__{pending_idle: nil}, _now), do: nil
  def next_ms(_t, _now), do: @pending_idle_recheck

  defp publish(old, new, effects) do
    state = effective(new)
    if state == effective(old), do: {new, effects}, else: {new, effects ++ [{:state, state}]}
  end
end
