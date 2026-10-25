defmodule HerdrServer.Client.Remote.Supervisor do
  @moduledoc "One `Client.Remote` conn per socket client."
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_conn(map) :: DynamicSupervisor.on_start_child()
  def start_conn(info),
    do: DynamicSupervisor.start_child(__MODULE__, {HerdrServer.Client.Remote, info})
end
