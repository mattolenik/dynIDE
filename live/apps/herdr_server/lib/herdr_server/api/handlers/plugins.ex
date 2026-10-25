defmodule HerdrServer.Api.Handlers.Plugins do
  @moduledoc """
  The `plugin.*` methods and `pane.link.activate`. Published ahead of their M14 tasks:
  each answers `not_available` naming the task that serves it.
  """

  @task3 ~w(plugin.install plugin.link plugin.uninstall plugin.enable plugin.disable
            plugin.config_dir plugin.list)
  @task4 ~w(plugin.action.list plugin.action.invoke plugin.log.list)
  @task5 ~w(plugin.pane.open plugin.pane.focus plugin.pane.close)

  @spec handle(String.t(), map()) :: {:error, :not_available, String.t(), map()}
  def handle(method, _params),
    do:
      {:error, :not_available, "#{method} is not served yet",
       %{requires: "M14 task #{task(method)}"}}

  defp task(m) when m in @task3, do: 3
  defp task(m) when m in @task4, do: 4
  defp task(m) when m in @task5, do: 5
  defp task("pane.link.activate"), do: 6
end
