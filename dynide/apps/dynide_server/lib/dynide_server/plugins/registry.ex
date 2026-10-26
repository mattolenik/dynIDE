defmodule DynideServer.Plugins.Registry do
  @moduledoc """
  `plugins.json` (herdr's shape: a JSON array of `plugin_id`, `plugin_root`, `manifest_path`,
  `enabled`, `source`), read on every call; no process holds it. `plugins/0` merges each
  entry with a fresh `Manifest.load/1`, so a manifest edited on disk shows on the next read;
  a failed load sets `error` and the plugin is never run. A corrupt file and each newly
  broken manifest are logged and toasted once (until they change).
  """

  alias DynideServer.Plugins.{Alert, Manifest, Paths, Runtime}

  @entry_keys ~w(plugin_id plugin_root manifest_path enabled source)
  @empty %{
    "name" => "",
    "version" => "",
    "min_herdr_version" => "",
    "description" => nil,
    "platforms" => nil,
    "build" => [],
    "startup" => [],
    "actions" => [],
    "events" => [],
    "panes" => [],
    "link_handlers" => [],
    "warnings" => []
  }

  @type entry :: %{String.t() => term()}
  @type plugin :: %{String.t() => term()}

  @spec entries() :: [entry()]
  def entries do
    case read() do
      {:ok, entries} ->
        seen(:registry, nil)
        entries

      {:error, why} ->
        now = {Paths.registry(), why}

        if seen(:registry, now) != now,
          do: Alert.show("#{Paths.registry()}: #{why}; no plugins loaded")

        []
    end
  end

  @spec plugins() :: [plugin()]
  def plugins do
    plugins = Enum.map(entries(), &merge/1)

    broken =
      for %{"error" => e} = p <- plugins, e != nil, into: MapSet.new(), do: {p["plugin_id"], e}

    old = seen(:manifests, broken) || MapSet.new()
    for {id, e} <- broken, not MapSet.member?(old, {id, e}), do: Alert.show("#{id}: #{e}")
    plugins
  end

  @doc "By plugin id, or by GitHub `owner/repo[/subdir]`."
  @spec find(String.t()) :: {:ok, plugin()} | :error
  def find(target) do
    case Enum.find(plugins(), &(&1["plugin_id"] == target or github(&1["source"]) == target)) do
      nil -> :error
      p -> {:ok, p}
    end
  end

  @doc "Read (strict), apply `fun`, sort by id, write atomically. Answers the new entries."
  @spec update(([entry()] -> [entry()])) :: {:ok, [entry()]} | {:error, term()}
  def update(fun) do
    # ponytail: serialised within this VM only, no cross-process file lock; the CLI goes
    # through the server. herdr's flock on `.plugins.lock` if another writer appears.
    :global.trans({__MODULE__, self()}, fn ->
      with {:ok, entries} <- read(),
           new =
             entries
             |> fun.()
             |> Enum.map(&Map.take(&1, @entry_keys))
             |> Enum.sort_by(& &1["plugin_id"]),
           :ok <- write(new) do
        Runtime.refresh()
        {:ok, new}
      end
    end)
  end

  defp read do
    case File.read(Paths.registry()) do
      {:error, :enoent} -> {:ok, []}
      {:error, e} -> {:error, :file.format_error(e) |> to_string()}
      {:ok, text} -> decode(text)
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(
             list,
             &(is_map(&1) and is_binary(&1["plugin_id"]) and is_binary(&1["manifest_path"]))
           ),
           do: {:ok, Enum.map(list, &Map.take(&1, @entry_keys))},
           else: {:error, "invalid plugin entry"}

      {:ok, _} ->
        {:error, "expected a JSON array"}

      {:error, e} ->
        {:error, "invalid JSON: #{inspect(e)}"}
    end
  end

  defp write(entries) do
    dir = Paths.config_dir()
    tmp = Paths.registry() <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- ok_if_absent(File.rm(tmp)),
         # exclusive: a fresh file (never a planted link), 0600 before any byte is written
         {:ok, f} <- File.open(tmp, [:write, :exclusive, :binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- IO.binwrite(f, JSON.encode!(entries)),
         :ok <- File.close(f),
         do: File.rename(tmp, Paths.registry())
  end

  defp ok_if_absent({:error, :enoent}), do: :ok
  defp ok_if_absent(r), do: r

  defp merge(entry) do
    case Manifest.load(entry["manifest_path"]) do
      {:ok, m} ->
        m |> Map.merge(entry) |> Map.put("error", nil)

      {:error, reason, message} ->
        @empty |> Map.merge(entry) |> Map.put("error", "#{reason}: #{message}")
    end
  end

  defp github(%{"kind" => "github", "owner" => o, "repo" => r} = s),
    do: Enum.join([o, r | List.wrap(s["subdir"])], "/")

  defp github(_), do: nil

  # remembers the last problem of `kind`, answering the previous one; a write only on change
  defp seen(kind, now) do
    key = {__MODULE__, kind}
    old = :persistent_term.get(key, nil)
    if old != now, do: :persistent_term.put(key, now)
    old
  end
end
