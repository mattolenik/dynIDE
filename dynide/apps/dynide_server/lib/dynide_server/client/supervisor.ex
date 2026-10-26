defmodule DynideServer.Client.Supervisor do
  @moduledoc "One `Client.Session` per attached client."
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_session(map) :: DynamicSupervisor.on_start_child()
  def start_session(info),
    do: DynamicSupervisor.start_child(__MODULE__, {DynideServer.Client.Session, info})
end
