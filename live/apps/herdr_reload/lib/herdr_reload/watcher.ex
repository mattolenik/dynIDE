defmodule HerdrReload.Watcher do
  @moduledoc """
  Watches source dirs and hands debounced batches of changed files to `on_batch`.

  Options: `dirs`, `debounce_ms` (50), `on_batch` (default `TestGate.reload/1`, run in
  a spawned process so events keep flowing), `backend_opts` for `FileSystem`.
  Returns `:ignore` (after a warning) when no file watcher backend can start.
  """

  use GenServer

  alias HerdrReload.TestGate

  require Logger

  @exts ~w(.ex .exs .erl .hrl .eex .heex)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    dirs = Keyword.get_lazy(opts, :dirs, &default_dirs/0)
    backend_opts = Keyword.get_lazy(opts, :backend_opts, &default_backend_opts/0)

    case FileSystem.start_link([dirs: dirs] ++ backend_opts) do
      {:ok, fs} ->
        FileSystem.subscribe(fs)

        {:ok,
         %{
           debounce: Keyword.get(opts, :debounce_ms, 50),
           on_batch: Keyword.get(opts, :on_batch, &TestGate.reload/1),
           paths: MapSet.new(),
           timer: nil
         }}

      other ->
        Logger.warning(
          "reload watcher disabled, file system backend unavailable: #{inspect(other)}"
        )

        :ignore
    end
  end

  @impl true
  def handle_info({:file_event, _, {path, _events}}, s) do
    if Path.extname(path) in @exts do
      if s.timer, do: Process.cancel_timer(s.timer)
      # the message carries the timer ref: a fire sent before cancel_timer took effect is stale
      timer = :erlang.start_timer(s.debounce, self(), :fire)
      {:noreply, %{s | paths: MapSet.put(s.paths, path), timer: timer}}
    else
      {:noreply, s}
    end
  end

  def handle_info({:timeout, ref, :fire}, %{timer: ref} = s) do
    paths = s.paths |> MapSet.to_list() |> Enum.sort()
    on_batch = s.on_batch
    if paths != [], do: spawn(fn -> on_batch.(paths) end)
    {:noreply, %{s | paths: MapSet.new(), timer: nil}}
  end

  def handle_info(_, s), do: {:noreply, s}

  # macOS fsevents defaults to 0.5s latency, which alone blows the save-to-loaded budget.
  defp default_backend_opts do
    case :os.type() do
      {:unix, :darwin} -> [latency: 0, no_defer: true]
      _ -> []
    end
  end

  defp default_dirs do
    root = Path.dirname(Mix.Project.project_file())
    umbrella = Path.wildcard(Path.join(root, "apps/*/lib"))
    if umbrella == [], do: [Path.join(root, "lib")], else: umbrella
  end
end
