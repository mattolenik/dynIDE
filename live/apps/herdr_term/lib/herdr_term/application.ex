defmodule HerdrTerm.Application do
  @moduledoc """
  Starts `HerdrTerm.Registry` and, unless headless (`HERDR_LIVE_HEADLESS=1` or
  `config :herdr_term, :headless`), the local terminal client `HerdrTerm.LocalClient`.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    headless? =
      System.get_env("HERDR_LIVE_HEADLESS") == "1" or
        Application.get_env(:herdr_term, :headless, false)

    client = if headless?, do: [], else: [{HerdrTerm.Client, name: HerdrTerm.LocalClient}]
    children = [{Registry, keys: :unique, name: HerdrTerm.Registry} | client]

    with {:ok, _} = ok <-
           Supervisor.start_link(children, strategy: :one_for_one, name: HerdrTerm.Supervisor) do
      if not headless?, do: Logger.info("terminal client started")
      ok
    end
  end
end
