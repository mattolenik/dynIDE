defmodule DynideServer.App.Store.Config do
  @moduledoc """
  The Store's side of the config file (M13, `DynideServer.Config`): loading, writes and
  diagnostics, through `DynideReload.Guard`. Takes and returns the Store state as a plain
  map, as `Store.Carry` and `Store.Mirror` do; notices come back for the Store to send.

    * `load/0`: the loaded config, or nil when loading itself fails (the file's own
      problems are diagnostics in the config).
    * `write/2`: `Config.Write.upsert/3` at `Config.path/0`; nil, or a warning notice.
    * `reload/0`: loads and casts `{:config_loaded, cfg}` to the Store; an info notice
      `reloaded config` when the file loaded (a failed one only warns, as diagnostics).
    * `diagnostics/2`: a non-empty list becomes one warning notice to every subscriber,
      kept in `state.diag` for later subscribers (`subscribed/2`) until a clean load.
  """

  alias DynideReload.Guard
  alias DynideServer.App.Store
  alias DynideServer.Config

  @spec load() :: Config.t() | nil
  def load do
    case Guard.run_twice(Config, :load, [], server: Store.reload_server()) do
      {:ok, cfg} -> cfg
      {:failed, _} -> nil
    end
  end

  @spec write([binary], map) :: map | nil
  def write(table, kv) do
    case Guard.run_twice(Config.Write, :upsert, [Config.path(), table, kv],
           server: Store.reload_server()
         ) do
      {:ok, :ok} -> nil
      {:ok, err} -> warning("config write failed: #{inspect(err)}")
      {:failed, f} -> warning("config write failed: #{Guard.message(f)}")
    end
  end

  @spec reload() :: map | nil
  def reload do
    case load() do
      nil ->
        nil

      cfg ->
        Store.event_async({:config_loaded, cfg})
        unless cfg.failed, do: %{level: :info, text: "reloaded config"}
    end
  end

  @spec diagnostics(map, [binary]) :: map
  def diagnostics(state, diags) do
    n = if diags != [], do: warning(Enum.join(diags, "; "))
    if n, do: Enum.each(Map.keys(state.subs), &send(&1, {:notice, n}))
    %{state | diag: n}
  end

  @doc "A new subscriber gets the standing diagnostics."
  @spec subscribed(map, pid) :: :ok
  def subscribed(%{diag: nil}, _pid), do: :ok

  def subscribed(%{diag: n}, pid) do
    send(pid, {:notice, n})
    :ok
  end

  defp warning(text), do: %{level: :warning, text: text}
end
