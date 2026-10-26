defmodule DynideReload.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:dynide_reload, DynideReload, [])
    children = if config[:enabled] && !config[:defer], do: [DynideReload.Supervisor], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: DynideReload.AppSupervisor)
  end

  @doc """
  Starts the reload pipeline that `defer: true` held back at application start (a VM
  that may be a handoff standby). A no-op when reload is disabled or already running.
  """
  @spec start_deferred() :: :ok
  def start_deferred do
    if Application.get_env(:dynide_reload, DynideReload, [])[:enabled] do
      case Supervisor.start_child(DynideReload.AppSupervisor, DynideReload.Supervisor) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    :ok
  end
end
