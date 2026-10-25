defmodule HerdrServer.Plugins.Keybind do
  @moduledoc """
  Keybinds that run a plugin action. A binding stores `mfa/1` (persisted state holds no
  funs); running it emits `{:plugin, {:invoke, command, %{source: "keybinding"}}}`, which
  `App.Store` hands to `Plugins.Runtime`.
  """

  @spec mfa(String.t()) :: {module(), atom(), [String.t()]}
  def mfa(command) when is_binary(command), do: {__MODULE__, :invoke, [command]}

  @spec invoke(map(), String.t()) :: {map(), [tuple()]}
  def invoke(app, command), do: {app, [{:plugin, {:invoke, command, %{source: "keybinding"}}}]}
end
