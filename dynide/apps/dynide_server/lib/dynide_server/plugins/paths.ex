defmodule DynideServer.Plugins.Paths do
  @moduledoc """
  Where plugins live on disk, re-rooted at `dynide/` (herdr's layout otherwise). Bases
  resolve at call time: app env `:plugins` `:config_dir` / `:state_dir` win, then XDG.
  """

  @max_component 120
  @reserved ~w(CON PRN AUX NUL COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9
               LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9)

  @spec config_dir() :: Path.t()
  def config_dir, do: base(:config_dir, "XDG_CONFIG_HOME", ".config")

  @spec state_dir() :: Path.t()
  def state_dir, do: base(:state_dir, "XDG_STATE_HOME", ".local/state")

  @spec registry() :: Path.t()
  def registry, do: Path.join(config_dir(), "plugins.json")

  @spec plugin_config_dir(String.t()) :: Path.t()
  def plugin_config_dir(id), do: Path.join([config_dir(), "plugins", "config", encode(id)])

  @spec plugin_state_dir(String.t()) :: Path.t()
  def plugin_state_dir(id), do: Path.join([state_dir(), "plugins", encode(id)])

  @spec installations_dir(String.t()) :: Path.t()
  def installations_dir(id),
    do: Path.join([config_dir(), "plugins", "github-installations", managed_component(id)])

  @spec ensure_user_dirs(String.t()) :: :ok | {:error, term()}
  def ensure_user_dirs(id) do
    with :ok <- File.mkdir_p(plugin_config_dir(id)), do: File.mkdir_p(plugin_state_dir(id))
  end

  @doc "herdr's `plugin_config_path_component`: injective, never `.`/`..`, never escapes."
  @spec encode(String.t()) :: String.t()
  def encode(id) do
    c =
      for <<b <- id>>, into: "" do
        if b in ?a..?z or b in ?0..?9 or b in [?., ?_, ?-],
          do: <<b>>,
          else: "%" <> Base.encode16(<<b>>)
      end

    c = if String.ends_with?(c, "."), do: String.slice(c, 0..-2//1) <> "%2E", else: c

    if c == "", do: "%plugin", else: c |> reserve() |> clip(id)
  end

  defp reserve(c), do: if(reserved?(c), do: "%" <> c, else: c)

  defp clip(c, id) do
    if String.length(c) > @max_component do
      h = hash(id)
      String.slice(c, 0, @max_component - String.length(h) - 1) <> "-" <> h
    else
      c
    end
  end

  # herdr's `plugin_managed_path_component`: readable slug plus a 12-hex sha256 prefix.
  defp managed_component(id), do: slug(id) <> "-" <> hash(id)

  defp slug(id) do
    s =
      id
      |> String.graphemes()
      |> Enum.map_join(fn g -> if g =~ ~r/\A[A-Za-z0-9\-_.]\z/, do: g, else: "-" end)
      |> String.replace(~r/-{2,}/, "-")
      |> String.replace(~r/\A[-_.]+|[-_.]+\z/, "")

    s = if s == "", do: "plugin", else: String.slice(s, 0, 80)
    if reserved?(s), do: String.replace(s, ".", "-"), else: s
  end

  defp reserved?(c),
    do: c |> String.split(".") |> hd() |> String.upcase() |> then(&(&1 in @reserved))

  defp hash(id), do: :crypto.hash(:sha256, id) |> binary_part(0, 6) |> Base.encode16(case: :lower)

  defp base(key, xdg, fallback) do
    case Application.get_env(:dynide_server, :plugins, [])[key] do
      nil -> Path.join(env(xdg) || Path.join(System.user_home!(), fallback), "dynide")
      dir -> dir
    end
  end

  defp env(name), do: with(v when v not in [nil, ""] <- System.get_env(name), do: v)
end
