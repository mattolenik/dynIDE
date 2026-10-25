defmodule HerdrServer.WorkspaceFacts do
  @moduledoc """
  Polls per-workspace runtime facts every `poll_ms` (2 s) and tells the Store when one
  changed. Today: each workspace's root pane (its first tab's first pane) cwd and its
  `Workspaces.Label.auto/1`, sent as the server-internal `{:workspace_cwd, ws_id, cwd,
  label}` (`App.Workspaces.workspace_cwd/4`), only when the cwd differs from the last one
  sent; an unknown (nil) cwd is not sent. The label's `File.stat` walk-up runs here, never
  in the Store, so a hung mount stalls this poller only.

  The app is read from the mirror (`Mirror.app/0`); the scan runs through
  `HerdrReload.Guard.run_twice/4`, so a bad edit is logged and skips a tick. It runs whether or not persistence is
  on; `enabled: false` in the `HerdrServer.WorkspaceFacts` app env (test) makes
  `start_link/1` return `:ignore`. Start opts (over the env), for tests: `cwd`, `app` and
  `notify` as `{m, f}` (defaults `{Persist.Facts, :cwd}`, `{Mirror, :app}`,
  `{App.Store, :event_async}`), `poll_ms`, `name`.
  """

  use GenServer

  alias HerdrReload.Guard
  alias HerdrServer.App.Store
  alias HerdrServer.App.Workspaces.Label
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

    case Guard.run_twice(__MODULE__, :scan, [state.app, state.cwd, state.sent],
           server: Store.reload_server()
         ) do
      {:ok, changed} -> {:noreply, %{state | sent: send_changed(changed, state)}}
      {:failed, _} -> {:noreply, state}
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

  defp send_changed({cwds, events}, %{notify: {m, f}, sent: sent}) do
    Enum.each(events, &apply(m, f, [&1]))
    # closed workspaces drop out; a nil this tick keeps the last one sent
    for {ws_id, cwd} <- cwds, last = cwd || sent[ws_id], last != nil, into: %{}, do: {ws_id, last}
  end
end
