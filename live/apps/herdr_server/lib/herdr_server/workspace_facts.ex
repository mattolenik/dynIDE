defmodule HerdrServer.WorkspaceFacts do
  @moduledoc """
  Polls per-workspace runtime facts every `poll_ms` (2 s) and tells the Store when one
  changed. Today: each workspace's root pane (its first tab's first pane) cwd, sent as the
  server-internal `{:workspace_cwd, ws_id, cwd}` (`App.Workspaces.workspace_cwd/3`), only
  when it differs from the last one sent; an unknown (nil) cwd is not sent.

  The app is read from the mirror (`Mirror.app/0`); the scan runs through
  `HerdrReload.Guard`, so a bad edit skips a tick. It runs whether or not persistence is
  on; `enabled: false` in the `HerdrServer.WorkspaceFacts` app env (test) makes
  `start_link/1` return `:ignore`. Start opts (over the env), for tests: `cwd`, `app` and
  `notify` as `{m, f}` (defaults `{Persist.Facts, :cwd}`, `{Mirror, :app}`,
  `{App.Store, :event_async}`), `poll_ms`, `name`.
  """

  use GenServer

  alias HerdrReload.Guard
  alias HerdrServer.App.Store
  alias HerdrServer.{Layout, Mirror}
  alias HerdrServer.Persist.Facts

  defstruct cwd: {Facts, :cwd},
            app: {Mirror, :app},
            notify: {Store, :event_async},
            poll_ms: 2000,
            sent: %{}

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:herdr_server, __MODULE__, []), opts)

    if Keyword.get(opts, :enabled, true),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__)),
      else: :ignore
  end

  @impl true
  def init(opts) do
    state = struct(__MODULE__, Keyword.take(opts, [:cwd, :app, :notify, :poll_ms]))
    Process.send_after(self(), :poll, state.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :poll, state.poll_ms)

    case Guard.run(__MODULE__, :scan, [state.app, state.cwd], server: Store.reload_server()) do
      {:ok, cwds} -> {:noreply, %{state | sent: send_changed(cwds, state)}}
      {:failed, _} -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  # %{ws_id => root-pane cwd or nil} of the app `{m, f}` returns (none when it is nil)
  @spec scan({module, atom}, {module, atom}) :: %{pos_integer => binary | nil}
  def scan({am, af}, {m, f}) do
    case apply(am, af, []) do
      nil ->
        %{}

      app ->
        for %{id: ws_id, tabs: [tab | _]} <- app.session.workspaces,
            into: %{},
            do: {ws_id, apply(m, f, [hd(Layout.pane_ids(tab.layout))])}
    end
  end

  defp send_changed(cwds, %{notify: {m, f}, sent: sent}) do
    for {ws_id, cwd} <- cwds,
        cwd != nil,
        Map.get(sent, ws_id) != cwd,
        do: apply(m, f, [{:workspace_cwd, ws_id, cwd}])

    # closed workspaces drop out; a nil this tick keeps the last one sent
    for {ws_id, cwd} <- cwds, last = cwd || sent[ws_id], last != nil, into: %{}, do: {ws_id, last}
  end
end
