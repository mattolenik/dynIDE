defmodule HerdrServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: HerdrServer.Worker.start_link(arg)
      # {HerdrServer.Worker, arg}
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
