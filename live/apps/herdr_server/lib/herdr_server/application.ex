defmodule HerdrServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias HerdrServer.Handoff

  @impl true
  def start(_type, _args) do
    :ok = HerdrServer.Kernel.load()
    # interactive mode loads modules lazily: a first View.compute would pay that inside its
    # 50 ms budget, time out, and leave the client without a scene until the app changes
    Handoff.Link.preload()
    keeper = HerdrServer.Kernel.keeper()
    # a configured fake keeper runs beside the real one (M1's own tests need Native.Keeper)
    fake_keeper = if keeper == HerdrServer.Native.Keeper, do: [], else: [keeper]

    # Order follows design.md "Supervision trees": Keeper, the table owner, then the app. Reload is
    # its own app (herdr_reload), started before this one as a dependency.
    # The handoff Link comes first: with a broker it blocks until FRESH or an adoption,
    # which the Keeper claims in its init. Snapshotter ignores itself without a broker.
    children =
      [
        Handoff.Notice,
        Handoff.Link,
        HerdrServer.Native.Keeper,
        HerdrServer.Mirror,
        Handoff.Snapshotter
      ] ++
        fake_keeper ++
        [
          {Registry, keys: :duplicate, name: HerdrServer.Client.Registry},
          {Registry, keys: :unique, name: HerdrServer.Pane.Registry},
          # before the Store: an adopting Store starts its panes' servers in init
          HerdrServer.Pane.Supervisor,
          HerdrServer.App.Store,
          HerdrServer.WorkspaceFacts,
          HerdrServer.Client.Supervisor,
          HerdrServer.Client.Endpoint,
          HerdrServer.ReloadNotices,
          {Registry, keys: :unique, name: HerdrServer.Client.Remote.Registry},
          HerdrServer.Client.Remote.Supervisor
        ] ++
        client_socket() ++
        api() ++
        plugins() ++
        [
          # last: it stops first, writing a final snapshot while Store and Keeper still run;
          # ignores itself unless persistence is enabled
          HerdrServer.Persist.Writer
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HerdrServer.Supervisor]

    # the reload server (herdr_reload, started first) snapshots the app at each batch
    reload = Application.get_env(:herdr_reload, HerdrReload, [])
    state_at_load = {HerdrServer.Mirror, :app, []}

    Application.put_env(
      :herdr_reload,
      HerdrReload,
      Keyword.put(reload, :state_at_load, state_at_load)
    )

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # before RESTORED (which drops unclaimed entries); not in Client.Socket.init, which
      # THAW reruns from inside the Link
      :ok = HerdrServer.Client.Remote.Supervisor.adopt_all()
      :ok = Handoff.Link.restored()
      # held back in a VM that could have been a standby (config/runtime.exs)
      :ok = HerdrReload.Application.start_deferred()
      # subscribe now: a first reload would otherwise land before the 500 ms retry
      if Process.whereis(HerdrServer.ReloadNotices),
        do: send(HerdrServer.ReloadNotices, :subscribe)

      announce_start()
      {:ok, pid}
    end
  end

  @doc false
  @spec announce_start() :: :ok
  def announce_start do
    Logger.info("herdr-live started")

    HerdrReload.Telemetry.event(:vm_start,
      gen: gen(),
      role: :primary,
      adopt: Handoff.Link.adopt_reason() || :fresh
    )
  end

  defp gen do
    case System.get_env("HERDR_LIVE_GEN") do
      v when v in [nil, ""] -> "0"
      v -> v
    end
  end

  # off in test: tests start their own listener on a tmp path (and event hub)
  defp api do
    if Application.get_env(:herdr_server, :api, [])[:enabled],
      do: [HerdrServer.Api.Events, {HerdrServer.Api.Listener, []}],
      else: []
  end

  # off in test: tests start their own listener on a tmp path
  defp client_socket do
    if Application.get_env(:herdr_server, :client_socket, [])[:enabled],
      do: [{HerdrServer.Client.Socket, []}],
      else: []
  end

  # off in test: tests start their own runtime with tmp plugin dirs
  defp plugins do
    if Application.get_env(:herdr_server, :plugins, [])[:enabled],
      do: [
        {Task.Supervisor, name: HerdrServer.Plugins.Tasks},
        HerdrServer.Plugins.Runtime
      ],
      else: []
  end

  @impl true
  def stop(_state) do
    Logger.info("herdr-live stopped")
    HerdrReload.Telemetry.event(:vm_stop, gen: gen())
  end
end
