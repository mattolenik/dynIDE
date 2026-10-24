defmodule HerdrReload.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:herdr_reload, HerdrReload, [])
    children = if config[:enabled], do: [HerdrReload.Supervisor], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: HerdrReload.AppSupervisor)
  end
end
