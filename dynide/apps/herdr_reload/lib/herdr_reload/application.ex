defmodule HerdrReload.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:herdr_reload, HerdrReload, [])
    children = if config[:enabled] && !config[:defer], do: [HerdrReload.Supervisor], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: HerdrReload.AppSupervisor)
  end

  @doc """
  Starts the reload pipeline that `defer: true` held back at application start (a VM
  that may be a handoff standby). A no-op when reload is disabled or already running.
  """
  @spec start_deferred() :: :ok
  def start_deferred do
    if Application.get_env(:herdr_reload, HerdrReload, [])[:enabled] do
      case Supervisor.start_child(HerdrReload.AppSupervisor, HerdrReload.Supervisor) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    :ok
  end
end
