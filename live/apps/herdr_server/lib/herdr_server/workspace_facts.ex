defmodule HerdrServer.WorkspaceFacts do
  @moduledoc """
  Polls per-workspace runtime facts every `poll_ms` (2 s) and tells the Store when one
  changed. Today: each workspace's root pane (its first tab's first pane) cwd and its
  `Workspaces.Label.auto/1`, sent as the server-internal `{:workspace_cwd, ws_id, cwd,
  label}` (`App.Workspaces.workspace_cwd/4`), only when the cwd differs from the last one
  sent; an unknown (nil) cwd is not sent. The label's `File.stat` walk-up runs here, never
  in the Store, so a hung mount stalls this poller only.

  On its own `git_ms` (5 s) timer it runs `git` (`GitStatus.status/1`) once per distinct
  `workspace.cwd`, each in an unlinked process that sends its result back, so this
  process never waits on git. A cwd whose call is still out gets no new one; past 2 s it
  counts as nil (as does no git, or no repo) until the call answers. `{:workspace_git, ws_id, info | nil}` is sent only when a workspace's info
  changed.

  The app is read from the mirror (`Mirror.app/0`); the scan runs through
  `HerdrReload.Guard.run_twice/4`, so a bad edit is logged and skips a tick. It runs whether or not persistence is
  on; `enabled: false` in the `HerdrServer.WorkspaceFacts` app env (test) makes
  `start_link/1` return `:ignore`. Start opts (over the env), for tests: `cwd`, `app` and
  `notify` and `git` as `{m, f}` (defaults `{Persist.Facts, :cwd}`, `{Mirror, :app}`,
  `{App.Store, :event_async}`, `{GitStatus, :status}`), `poll_ms`, `git_ms`, `name`.
  """

  use GenServer

  alias HerdrReload.Guard
  alias HerdrServer.App.Store
  alias HerdrServer.App.Workspaces.Label
  alias HerdrServer.{GitStatus, Layout, Mirror}
  alias HerdrServer.Persist.Facts

  defstruct cwd: {Facts, :cwd},
            app: {Mirror, :app},
            notify: {Store, :event_async},
            git: {GitStatus, :status},
            poll_ms: 2000,
            git_ms: 5000,
            sent: %{},
            git_sent: %{},
            git_wss: %{},
            git_by_cwd: %{},
            git_inflight: %{}

  @git_timeout_ms 2000

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:herdr_server, __MODULE__, []), opts)

    if Keyword.get(opts, :enabled, true),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__)),
      else: :ignore
  end

  @impl true
  def init(opts) do
    state = struct(__MODULE__, Keyword.take(opts, [:cwd, :app, :notify, :git, :poll_ms, :git_ms]))
    Process.send_after(self(), :poll, state.poll_ms)
    Process.send_after(self(), :git_poll, state.git_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :poll, state.poll_ms)

    case Guard.run_twice(__MODULE__, :scan, [state.app, state.cwd, state.sent],
           server: Store.reload_server()
         ) do
      {:ok, changed} -> {:noreply, %{state | sent: send_changed(changed, state)}}
      {:failed, _} -> {:noreply, state}
    end
  end

  # each tick: refresh the workspace cwds, start a call for every cwd without one in
  # flight, and count a call older than the budget as nil (it is never restarted while
  # it hangs, so a hung repo holds one git process, not one per tick)
  def handle_info(:git_poll, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :git_poll, state.git_ms)

    case Guard.run_twice(__MODULE__, :git_cwds, [state.app], server: Store.reload_server()) do
      {:ok, wss} ->
        now = System.monotonic_time(:millisecond)
        cwds = wss |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()
        new = cwds -- Map.keys(state.git_inflight)
        # a call for a cwd no workspace has any more still finishes: it stays in flight
        inflight =
          Map.merge(state.git_inflight, Map.new(new, &{&1, start_git(&1, state.git, now)}))

        stale =
          for {cwd, {t, _ref}} <- Map.take(inflight, cwds),
              now - t >= @git_timeout_ms,
              into: %{},
              do: {cwd, nil}

        by_cwd = state.git_by_cwd |> Map.take(cwds) |> Map.merge(stale)

        {:noreply, emit_git(%{state | git_wss: wss, git_inflight: inflight, git_by_cwd: by_cwd})}

      {:failed, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:git_result, cwd, info}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {entry, inflight} = Map.pop(state.git_inflight, cwd)
    with {_t, ref} <- entry, do: Process.demonitor(ref, [:flush])
    {:noreply, git_answer(%{state | git_inflight: inflight}, cwd, info)}
  end

  # a call process that died without answering (killed): its cwd is nil and polled again
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = Map.merge(%__MODULE__{}, state)

    case Enum.find(state.git_inflight, fn {_cwd, {_t, r}} -> r == ref end) do
      {cwd, _} ->
        state = %{state | git_inflight: Map.delete(state.git_inflight, cwd)}
        {:noreply, git_answer(state, cwd, nil)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  # `{cwds, events}` for the app `{m, f}` returns (none when it is nil): `cwds` is
  # %{ws_id => root-pane cwd or nil}; `events` the `{:workspace_cwd, ws_id, cwd, label}` of
  # each non-nil cwd that differs from `sent`'s
  @spec scan({module, atom}, {module, atom}, %{pos_integer => binary}) ::
          {%{pos_integer => binary | nil}, [tuple]}
  def scan({am, af}, {m, f}, sent) do
    cwds =
      case apply(am, af, []) do
        nil ->
          %{}

        app ->
          for %{id: ws_id, tabs: [tab | _]} <- app.session.workspaces,
              into: %{},
              do: {ws_id, apply(m, f, [hd(Layout.pane_ids(tab.layout))])}
      end

    events =
      for {ws_id, cwd} <- cwds,
          cwd != nil,
          Map.get(sent, ws_id) != cwd,
          do: {:workspace_cwd, ws_id, cwd, Label.auto(cwd)}

    {cwds, events}
  end

  @doc false
  # %{ws_id => workspace cwd or nil} of the app `{m, f}` returns (none when it is nil)
  @spec git_cwds({module, atom}) :: %{pos_integer => binary | nil}
  def git_cwds({am, af}) do
    case apply(am, af, []) do
      nil -> %{}
      app -> Map.new(app.session.workspaces, &{&1.id, Map.get(&1, :cwd)})
    end
  end

  # only for a cwd some workspace still has
  defp git_answer(state, cwd, info) do
    if cwd in Map.values(state.git_wss),
      do: emit_git(%{state | git_by_cwd: Map.put(state.git_by_cwd, cwd, info)}),
      else: state
  end

  # `{started_ms, monitor ref}`; unlinked, so a call can't take this process down; a
  # failing runner (bad edit) answers nil, a killed one is caught by its :DOWN
  defp start_git(cwd, {m, f}, now) do
    parent = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        info =
          case Guard.run_twice(m, f, [cwd], server: Store.reload_server()) do
            {:ok, info} -> info
            {:failed, _} -> nil
          end

        send(parent, {:git_result, cwd, info})
      end)

    {now, ref}
  end

  # `{:workspace_git, ws_id, info}` for each workspace whose info differs from the last sent
  defp emit_git(%{git_wss: wss, git_by_cwd: by_cwd, git_sent: sent, notify: {m, f}} = state) do
    infos = Map.new(wss, fn {id, cwd} -> {id, Map.get(by_cwd, cwd)} end)

    for {id, info} <- infos,
        Map.get(sent, id) != info,
        do: apply(m, f, [{:workspace_git, id, info}])

    %{state | git_sent: infos}
  end

  defp send_changed({cwds, events}, %{notify: {m, f}, sent: sent}) do
    Enum.each(events, &apply(m, f, [&1]))
    # closed workspaces drop out; a nil this tick keeps the last one sent
    for {ws_id, cwd} <- cwds, last = cwd || sent[ws_id], last != nil, into: %{}, do: {ws_id, last}
  end
end
