defmodule HerdrServer.Detect.Manifests do
  @moduledoc """
  The agent manifest store: bundled manifests (`priv/detect/manifests`) with
  per-agent user overrides (`<config dir>/agent-detection/<label>.toml`).

  Entries are keyed by agent label, the bundled file's `id`. An override wins
  when it parses and its `id` or an alias is the label; otherwise the bundled
  manifest stays active with a `warning`, as in herdr. A bundled file that does
  not parse yields an entry with `error` set and `manifest: nil`.

  The loaded entries live in `:persistent_term`; `reload/0` replaces them.
  """

  alias HerdrServer.Detect.{Identify, Manifest}

  @key {__MODULE__, :entries}

  @type entry :: %{
          agent: binary,
          manifest: Manifest.t() | nil,
          source: :bundled | :override,
          path: binary | nil,
          version: binary | nil,
          warning: binary | nil,
          error: binary | nil
        }

  @spec bundled_dir() :: binary
  def bundled_dir, do: Application.app_dir(:herdr_server, "priv/detect/manifests")

  @spec override_dir() :: binary
  def override_dir, do: Path.join(Path.dirname(HerdrServer.Config.path()), "agent-detection")

  @doc "Reads every bundled manifest and its override. No global state."
  @spec load(binary, binary) :: %{binary => entry}
  def load(bundled_dir, override_dir) do
    bundled_dir
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Map.new(fn path ->
      entry = bundled(path)
      {entry.agent, with_override(entry, override_dir)}
    end)
  end

  @doc "Reloads the store from disk and returns the new summaries."
  @spec reload() :: [map]
  def reload do
    entries = load(bundled_dir(), override_dir())
    :persistent_term.put(@key, entries)
    summaries(entries)
  end

  @spec get(binary) :: entry | nil
  def get(label), do: Map.get(entries(), label)

  @spec summaries() :: [map]
  def summaries, do: summaries(entries())

  defp entries do
    case :persistent_term.get(@key, nil) do
      nil ->
        reload()
        :persistent_term.get(@key)

      entries ->
        entries
    end
  end

  defp summaries(entries) do
    entries
    |> Map.values()
    |> Enum.sort_by(& &1.agent)
    |> Enum.map(fn e ->
      %{
        "agent" => e.agent,
        "source" => Atom.to_string(e.source),
        "version" => e.version,
        "path" => e.path,
        "warning" => e.warning,
        "error" => e.error
      }
    end)
  end

  defp bundled(path) do
    base = %{source: :bundled, path: nil, warning: nil, error: nil}

    case read(path) do
      {:ok, m} ->
        Map.merge(base, %{agent: m.id, manifest: m, version: m.version})

      {:error, err} ->
        label = raw_id(path)

        Map.merge(base, %{
          agent: label,
          manifest: nil,
          version: nil,
          error: "bundled #{label} manifest is invalid: #{err}"
        })
    end
  end

  # Label for a bundled file that failed validation: its `id` if the TOML still has one.
  defp raw_id(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{"id" => id}} when is_binary(id) <- Toml.decode(bin) do
      id
    else
      _ -> Path.basename(path, ".toml")
    end
  end

  defp with_override(entry, dir) do
    path = Path.join(dir, entry.agent <> ".toml")
    if File.exists?(path), do: override(entry, path, read(path)), else: entry
  end

  defp override(entry, path, {:ok, m}) do
    if entry.agent in [m.id | m.aliases] or
         entry.agent in Enum.map([m.id | m.aliases], &Identify.label/1) do
      %{
        entry
        | manifest: m,
          source: :override,
          path: path,
          version: m.version,
          warning: nil,
          error: nil
      }
    else
      warn(
        entry,
        "ignored override #{path} because manifest id #{m.id} does not match #{entry.agent}"
      )
    end
  end

  defp override(entry, path, {:error, err}),
    do: warn(entry, "ignored override #{path} because it could not be loaded: #{err}")

  defp warn(entry, warning), do: %{entry | warning: warning}

  defp read(path) do
    case File.read(path) do
      {:ok, bin} -> Manifest.parse(bin)
      {:error, reason} -> {:error, List.to_string(:file.format_error(reason))}
    end
  end
end
