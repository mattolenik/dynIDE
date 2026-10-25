defmodule HerdrServer.Detect.Watcher do
  @moduledoc """
  Reloads agent manifests when a `.toml` in the bundled or override dir changes.
  The override dir is created if absent; if that fails only the bundled dir is watched.
  """

  alias HerdrReload.Watcher
  alias HerdrServer.Detect.Manifests

  require Logger

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Watcher.start_link(
      [dirs: dirs(), exts: [".toml"], on_batch: &Manifests.reload_batch/1, debounce_ms: 50] ++
        opts
    )
  end

  defp dirs do
    override = Manifests.override_dir()

    case File.mkdir_p(override) do
      :ok ->
        [Manifests.bundled_dir(), override]

      {:error, reason} ->
        Logger.warning("manifest override dir #{override} unavailable: #{inspect(reason)}")
        [Manifests.bundled_dir()]
    end
  end
end
