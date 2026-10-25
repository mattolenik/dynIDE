defmodule HerdrServer.WorkspaceFacts do
  @moduledoc """
  Polls per-workspace runtime facts every `poll_ms` (2 s) and tells the Store when one
  changed. Today: each workspace's root pane (its first tab's first pane) cwd and its
  `Workspaces.Label.auto/1`, sent as the server-internal `{:workspace_cwd, ws_id, cwd,
  label}` (`App.Workspaces.workspace_cwd/4`), only when the cwd differs from the last one
  sent; an unknown (nil) cwd is not sent. The label's `File.stat` walk-up runs here, never
  in the Store, so a hung mount stalls this poller only.

  On its own `git_ms` (5 s) timer it runs `git` (`GitStatus.status/1`) once per distinct
  `workspace.cwd`, all in parallel, each in a `Task` given 2 s: a call that does not
  answer by then is shut down and counts as nil (as does no git, or no repo). `{:workspace_git, ws_id, info | nil}` is sent only when a workspace's info
  changed. Exits are trapped so a crashing call is a nil, not a restart.

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
            git_sent: %{}

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
    Process.flag(:trap_exit, true)
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

  def handle_info(:git_poll, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :git_poll, state.git_ms)

    case Guard.run_twice(__MODULE__, :git_scan, [state.app, state.git, state.git_sent],
           server: Store.reload_server()
         ) do
      {:ok, {infos, events}} ->
        {m, f} = state.notify
        Enum.each(events, &apply(m, f, [&1]))
        {:noreply, %{state | git_sent: infos}}

      {:failed, _} ->
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
  # `{infos, events}`: `infos` is %{ws_id => info or nil} for every workspace (nil without a
  # cwd); `events` the `{:workspace_git, ws_id, info}` of each that differs from `sent`'s
  @spec git_scan({module, atom}, {module, atom}, map) :: {map, [tuple]}
  def git_scan({am, af}, runner, sent) do
    wss =
      case apply(am, af, []) do
        nil -> []
        app -> for ws <- app.session.workspaces, do: {ws.id, Map.get(ws, :cwd)}
      end

    by_cwd = wss |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> git(runner)
    infos = Map.new(wss, fn {id, cwd} -> {id, Map.get(by_cwd, cwd)} end)
    events = for {id, info} <- infos, Map.get(sent, id) != info, do: {:workspace_git, id, info}
    {infos, events}
  end

  # %{cwd => info or nil}: one Task per cwd, nil past the timeout or on a crash
  defp git(cwds, {m, f}) do
    tasks = Enum.map(cwds, fn cwd -> Task.async(fn -> apply(m, f, [cwd]) end) end)

    tasks
    |> Task.yield_many(@git_timeout_ms)
    |> Enum.zip(cwds)
    |> Map.new(fn
      {{_task, {:ok, info}}, cwd} ->
        {cwd, info}

      {{task, _timeout_or_exit}, cwd} ->
        Task.shutdown(task, :brutal_kill)
        {cwd, nil}
    end)
  end

  defp send_changed({cwds, events}, %{notify: {m, f}, sent: sent}) do
    Enum.each(events, &apply(m, f, [&1]))
    # closed workspaces drop out; a nil this tick keeps the last one sent
    for {ws_id, cwd} <- cwds, last = cwd || sent[ws_id], last != nil, into: %{}, do: {ws_id, last}
  end
end
