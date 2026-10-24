defmodule HerdrServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    reload = Application.get_env(:herdr_server, HerdrServer.Reload, [])
    reload_children = if reload[:enabled], do: [HerdrServer.Reload.Supervisor], else: []

    :ok = HerdrServer.Kernel.load()
    keeper = HerdrServer.Kernel.keeper()
    # a configured fake keeper runs beside the real one (M1's own tests need Native.Keeper)
    fake_keeper = if keeper == HerdrServer.Native.Keeper, do: [], else: [keeper]

    # Order follows design.md "Supervision trees": Keeper, Reload, then the app.
    children =
      [HerdrServer.Native.Keeper] ++
        reload_children ++
        fake_keeper ++
        [
          HerdrServer.Pane.Rows,
          {Registry, keys: :duplicate, name: HerdrServer.Client.Registry},
          {Registry, keys: :unique, name: HerdrServer.Pane.Registry},
          HerdrServer.App.Store,
          HerdrServer.Pane.Supervisor,
          HerdrServer.Client.Supervisor,
          HerdrServer.Client.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HerdrServer.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      Logger.info("herdr-live started")
      {:ok, pid}
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("herdr-live stopped")
  end
end
