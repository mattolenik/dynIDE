defmodule DynideServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias DynideServer.Handoff

  @impl true
  def start(_type, _args) do
    :ok = DynideServer.Kernel.load()
    # interactive mode loads modules lazily: a first View.compute would pay that inside its
    # 50 ms budget, time out, and leave the client without a scene until the app changes
    Handoff.Link.preload()
    keeper = DynideServer.Kernel.keeper()
    # a configured fake keeper runs beside the real one (M1's own tests need Native.Keeper)
    fake_keeper = if keeper == DynideServer.Native.Keeper, do: [], else: [keeper]

    # Order follows design.md "Supervision trees": Keeper, the table owner, then the app. Reload is
    # its own app (dynide_reload), started before this one as a dependency.
    # The handoff Link comes first: with a broker it blocks until FRESH or an adoption,
    # which the Keeper claims in its init. Snapshotter ignores itself without a broker.
    children =
      [
        Handoff.Notice,
        Handoff.Link,
        DynideServer.Native.Keeper,
        DynideServer.Mirror,
        Handoff.Snapshotter
      ] ++
        fake_keeper ++
        [
          {Registry, keys: :duplicate, name: DynideServer.Client.Registry},
          {Registry, keys: :unique, name: DynideServer.Pane.Registry},
          # before the Store: an adopting Store starts its panes' servers in init
          DynideServer.Pane.Supervisor,
          {Task.Supervisor, name: DynideServer.App.Store.Tasks},
          DynideServer.App.Store,
          DynideServer.WorkspaceFacts,
          # reads the app from the Mirror; harmless while it has none
          DynideServer.Detect.Poller
        ] ++
        detect_watcher() ++
        [
          {Task.Supervisor, name: DynideServer.Client.Tasks},
          DynideServer.Client.Supervisor,
          DynideServer.Client.Endpoint,
          DynideServer.ReloadNotices,
          {Registry, keys: :unique, name: DynideServer.Client.Remote.Registry},
          DynideServer.Client.Remote.Supervisor
        ] ++
        client_socket() ++
        api() ++
        plugins() ++
        [
          # last: it stops first, writing a final snapshot while Store and Keeper still run;
          # ignores itself unless persistence is enabled
          DynideServer.Persist.Writer
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DynideServer.Supervisor]

    # the reload server (dynide_reload, started first) snapshots the app at each batch
    reload = Application.get_env(:dynide_reload, DynideReload, [])
    state_at_load = {DynideServer.Mirror, :app, []}

    Application.put_env(
      :dynide_reload,
      DynideReload,
      Keyword.put(reload, :state_at_load, state_at_load)
    )

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # before RESTORED (which drops unclaimed entries); not in Client.Socket.init, which
      # THAW reruns from inside the Link
      :ok = DynideServer.Client.Remote.Supervisor.adopt_all()
      :ok = Handoff.Link.restored()
      # held back in a VM that could have been a standby (config/runtime.exs)
      :ok = DynideReload.Application.start_deferred()
      # subscribe now: a first reload would otherwise land before the 500 ms retry
      if Process.whereis(DynideServer.ReloadNotices),
        do: send(DynideServer.ReloadNotices, :subscribe)

      announce_start()
      {:ok, pid}
    end
  end

  @doc false
  @spec announce_start() :: :ok
  def announce_start do
    Logger.info("dynide started")

    DynideReload.Telemetry.event(:vm_start,
      gen: gen(),
      role: :primary,
      adopt: Handoff.Link.adopt_reason() || :fresh
    )
  end

  defp gen do
    case System.get_env("DYNIDE_GEN") do
      v when v in [nil, ""] -> "0"
      v -> v
    end
  end

  # off in test: tests start their own listener on a tmp path (and event hub)
  defp api do
    if Application.get_env(:dynide_server, :api, [])[:enabled],
      do: [DynideServer.Api.Events, {DynideServer.Api.Listener, []}],
      else: []
  end

  # off in test: tests start their own listener on a tmp path
  defp client_socket do
    if Application.get_env(:dynide_server, :client_socket, [])[:enabled],
      do: [{DynideServer.Client.Socket, []}],
      else: []
  end

  # off in test: tests start their own with a tmp override dir
  defp detect_watcher do
    if Application.get_env(:dynide_server, :detect_watcher, [])[:enabled],
      do: [DynideServer.Detect.Watcher],
      else: []
  end

  # off in test: tests start their own runtime with tmp plugin dirs
  defp plugins do
    if Application.get_env(:dynide_server, :plugins, [])[:enabled],
      do: [
        {Task.Supervisor, name: DynideServer.Plugins.Tasks},
        DynideServer.Plugins.Runtime
      ],
      else: []
  end

  @impl true
  def stop(_state) do
    Logger.info("dynide stopped")
    DynideReload.Telemetry.event(:vm_stop, gen: gen())
  end
end
