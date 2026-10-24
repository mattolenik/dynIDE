defmodule HerdrReload.Notices do
  @moduledoc """
  Pub/sub for reload events. Subscribers receive `{:herdr_reload, event}`.

  Events: `{:compile_error, [diagnostic]}`, `{:loaded, batch_id, [module]}`,
  `{:rolled_back, batch_id, [module], reason}`, `{:rejected, module, path}`,
  `{:purge_blocked, module, [pid_info]}`.
  """

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

  @doc "Sends `event` to every subscriber; a no-op when the registry is not running."
  @spec broadcast(term()) :: :ok
  def broadcast(event) do
    if Process.whereis(__MODULE__) do
      Registry.dispatch(__MODULE__, :events, &deliver(&1, event))
    end

    :ok
  end

  defp deliver(entries, event) do
    for {pid, _} <- entries, do: send(pid, {:herdr_reload, event})
  end
end
