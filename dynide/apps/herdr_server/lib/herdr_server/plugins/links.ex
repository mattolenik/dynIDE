defmodule HerdrServer.Plugins.Links do
  @moduledoc """
  Plugin link handlers (herdr's `[[link_handlers]]`): a clicked URL matching a handler's
  pattern runs its action with `invocation_source "link_click"`, `clicked_url`,
  `link_handler_id` and `click_modifiers`. Called only on a ctrl+click that hit a link
  and on `pane.link.activate`, never on hover; the registry is read per call (as herdr).
  """

  alias HerdrServer.Plugins.{Alert, Manifest, Registry, Runtime}

  @modifiers ~w(shift alt ctrl)

  @doc """
  The first handler matching `url`: enabled, loadable plugins by id, handlers in manifest
  order, skipping a handler or action the platform does not support.
  """
  @spec find([map()], String.t()) :: {map(), map(), map()} | nil
  def find(plugins, url) do
    Enum.find_value(Enum.sort_by(plugins, & &1["plugin_id"]), fn p ->
      if p["enabled"] == true and p["error"] == nil do
        Enum.find_value(p["link_handlers"], &match(p, &1, url))
      end
    end)
  end

  defp match(p, h, url) do
    with true <- Manifest.platform_ok?(h["platforms"], p["platforms"]),
         %{} = a <- Enum.find(p["actions"], &(&1["id"] == h["action"])),
         true <- Manifest.platform_ok?(a["platforms"], p["platforms"]),
         {:ok, re} <- Regex.compile(h["pattern"]),
         true <- Regex.match?(re, url) do
      {p, h, a}
    else
      _ -> nil
    end
  end

  @doc "The held modifiers herdr can name, in its order (`shift`, `alt`, `ctrl`)."
  @spec modifiers([atom() | String.t()]) :: [String.t()]
  def modifiers(mods) do
    held = Enum.map(mods, &to_string/1)
    Enum.filter(@modifiers, &(&1 in held))
  end

  @doc """
  Runs the handler for `url` clicked in pane `pane_id`. `{:error, message}` has already
  shown an alert: herdr does not fall back to the browser after a failed launch.
  """
  @spec dispatch(String.t(), [atom() | String.t()], pos_integer()) ::
          :handled | :unhandled | {:error, String.t()}
  def dispatch(url, mods, pane_id) do
    case find(Registry.plugins(), url) do
      nil -> :unhandled
      {p, h, a} -> run(p, h, a, url, mods, pane_id)
    end
  end

  defp run(p, h, a, url, mods, pane_id) do
    overrides = %{
      :pane => pane_id,
      "clicked_url" => url,
      "link_handler_id" => h["id"],
      "click_modifiers" => with([] <- modifiers(mods), do: nil)
    }

    result =
      if Runtime.running?(),
        do: Runtime.invoke(a["id"], p["plugin_id"], overrides, "link_click"),
        else: {:error, "plugins_not_running", "plugins are not running"}

    case result do
      {:ok, _} ->
        :handled

      {:error, _reason, msg} ->
        Alert.show("#{p["plugin_id"]} link handler #{h["id"]}: #{msg}")
        {:error, msg}
    end
  catch
    :exit, reason ->
      msg = "plugin runtime did not answer: #{inspect(reason)}"
      Alert.show("#{p["plugin_id"]} link handler #{h["id"]}: #{msg}")
      {:error, msg}
  end
end
