defmodule DynideServer.Client.Remote.Supervisor do
  @moduledoc "One `Client.Remote` conn per socket client."
  use DynamicSupervisor

  alias DynideServer.Handoff.Link

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_conn(map) :: DynamicSupervisor.on_start_child()
  def start_conn(info),
    do: DynamicSupervisor.start_child(__MODULE__, {DynideServer.Client.Remote, info})

  @doc """
  Claims this VM's adopted `client/` entries and starts a conn for each. Called once by
  `DynideServer.Application` after the supervisor is up and before `Handoff.Link.restored/0`
  (unclaimed entries are dropped at RESTORED); never from a Link callback.
  """
  @spec adopt_all() :: :ok
  def adopt_all do
    for entry <- Link.take_adopted("client/"), do: start_adopted(entry)
    :ok
  end

  @doc "A conn for a `client/<id>` entry a new VM adopted (R11)."
  @spec start_adopted({binary, binary, list}) :: DynamicSupervisor.on_start_child()
  def start_adopted(entry),
    do: DynamicSupervisor.start_child(__MODULE__, {DynideServer.Client.Remote, {:adopted, entry}})
end
