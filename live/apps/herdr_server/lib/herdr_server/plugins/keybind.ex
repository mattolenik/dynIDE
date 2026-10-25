defmodule HerdrServer.Plugins.Keybind do
  @moduledoc """
  Keybinds and menu items that run a plugin action. A binding stores `mfa/1` (persisted
  state holds no funs); running it emits `{:plugin, {:invoke, command, meta}}`, which
  `App.Store` hands to `Plugins.Runtime`.
  """

  @spec mfa(String.t()) :: {module(), atom(), [String.t()]}
  def mfa(command) when is_binary(command), do: {__MODULE__, :invoke, [command]}

  @spec invoke(map(), String.t()) :: {map(), [tuple()]}
  def invoke(app, command), do: {app, [{:plugin, {:invoke, command, %{source: "keybinding"}}}]}

  @doc "A `Plugins.Menu` item: the menu's target is the context's pane, tab or workspace."
  @spec invoke_for(map(), String.t(), atom(), term()) :: {map(), [tuple()]}
  def invoke_for(app, command, menu, target),
    do: {app, [{:plugin, {:invoke, command, %{source: "menu", target: {menu, target}}}}]}
end
