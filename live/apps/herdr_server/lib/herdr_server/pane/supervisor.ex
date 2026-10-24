defmodule HerdrServer.Pane.Supervisor do
  @moduledoc "One `Pane.Server` per pane, registered in `HerdrServer.Pane.Registry`."
  use DynamicSupervisor

  alias HerdrServer.Pane.Server

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_pane(pos_integer) :: DynamicSupervisor.on_start_child()
  def start_pane(id), do: DynamicSupervisor.start_child(__MODULE__, {Server, id})

  @doc "Stops the pane's server; unknown panes are a no-op."
  @spec stop_pane(pos_integer) :: :ok
  def stop_pane(id) do
    for {pid, _} <- Registry.lookup(HerdrServer.Pane.Registry, id),
        do: DynamicSupervisor.terminate_child(__MODULE__, pid)

    :ok
  end
end
