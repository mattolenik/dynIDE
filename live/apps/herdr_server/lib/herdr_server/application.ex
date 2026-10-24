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
          HerdrServer.Client.Supervisor,
          HerdrServer.Client.Endpoint,
          HerdrServer.ReloadNotices
        ] ++ control()

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
      :ok = Handoff.Link.restored()
      # held back in a VM that could have been a standby (config/runtime.exs)
      :ok = HerdrReload.Application.start_deferred()
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

  defp gen, do: System.get_env("HERDR_LIVE_GEN") || "0"

  # the rollback socket only makes sense with the reload pipeline running
  defp control do
    if Application.get_env(:herdr_reload, HerdrReload, [])[:enabled],
      do: [{HerdrServer.Control, []}],
      else: []
  end

  @impl true
  def stop(_state) do
    Logger.info("herdr-live stopped")
    HerdrReload.Telemetry.event(:vm_stop, gen: gen())
  end
end
