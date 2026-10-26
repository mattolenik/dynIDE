defmodule DynideReload.Notices do
  @moduledoc """
  Pub/sub for reload events. Subscribers receive `{:dynide_reload, event}`.

  Events: `{:compile_error, [diagnostic]}`, `{:loaded, batch_id, [module]}`,
  `{:rolled_back, batch_id, [module], reason}`, `{:rejected, module, path}`,
  `{:purge_blocked, module, [pid_info]}`, `{:synced, [module]}` (the promotion sync
  loaded modules changed on disk).

  Every broadcast is also logged as a `dynide-event` line (`DynideReload.Telemetry`).
  """

  alias DynideReload.Telemetry

  @doc "Child spec for the duplicate-key registry backing the notices."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Subscribes the calling process to reload events."
  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _} = Registry.register(__MODULE__, :events, nil)
    :ok
  end

  @doc """
  Logs `event` as a telemetry line (`extra` adds fields) and sends it to every subscriber;
  without the registry only the log happens.
  """
  @spec broadcast(term(), keyword()) :: :ok
  def broadcast(event, extra \\ []) do
    with {kind, fields} <- Telemetry.from_notice(event, extra), do: Telemetry.event(kind, fields)

    if Process.whereis(__MODULE__) do
      Registry.dispatch(__MODULE__, :events, &deliver(&1, event))
    end

    :ok
  end

  defp deliver(entries, event) do
    for {pid, _} <- entries, do: send(pid, {:dynide_reload, event})
  end
end
