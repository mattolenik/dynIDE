defmodule HerdrServer.Plugins.Menu do
  @moduledoc """
  Plugin actions as M13 context-menu items. `items/3` is pure apart from reading a
  `:persistent_term` catalog that `Plugins.Runtime` refreshes (`refresh/1`) on each
  registry write and every 2 s. ponytail: a polling cache; push from `Registry.update/1`
  alone if staleness shows.

  An action shows in the menus its `contexts` name (`global` and empty contexts: the
  global menu; `selection` is ignored), when its plugin is enabled, loads, and runs on
  this platform.
  """

  alias HerdrServer.Plugins.{Keybind, Manifest, Registry}

  @key {__MODULE__, :catalog}
  @menus %{"global" => :global, "workspace" => :workspace, "tab" => :tab, "pane" => :pane}

  @type menu :: :tab | :workspace | :pane | :global

  @spec items(map(), menu(), term()) :: [{{:plugin, String.t()}, String.t(), tuple()}]
  def items(_app, menu, target) do
    for {id, title, menus} <- :persistent_term.get(@key, []),
        menu in menus,
        do: {{:plugin, id}, title, {Keybind, :invoke_for, [id, menu, target]}}
  end

  @doc "Rebuilds the catalog from `plugins` (default: a fresh registry read)."
  @spec refresh([map()]) :: :ok
  def refresh(plugins \\ Registry.plugins()) do
    put(
      for p <- plugins,
          p["enabled"] == true and p["error"] == nil,
          a <- p["actions"],
          Manifest.platform_ok?(a["platforms"], p["platforms"]),
          do: {a["qualified_id"], a["title"], menus(a["contexts"])}
    )
  end

  @doc "Sets the catalog; writes only on change (a `:persistent_term` write is global)."
  @spec put(list()) :: :ok
  def put(catalog) do
    if :persistent_term.get(@key, []) != catalog, do: :persistent_term.put(@key, catalog)
    :ok
  end

  defp menus([]), do: [:global]
  defp menus(contexts), do: for(c <- contexts, Map.has_key?(@menus, c), do: @menus[c])
end
