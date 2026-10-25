defmodule HerdrReload.Supervisor do
  @moduledoc "Supervises the reload pipeline; later children depend on earlier ones."

  use Supervisor

  alias HerdrReload.{Notices, Server, TestGate, Watcher}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([Notices, {Server, []}, TestGate, Watcher.child_spec([])], strategy: :rest_for_one)
  end
end
