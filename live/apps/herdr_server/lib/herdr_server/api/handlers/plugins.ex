defmodule HerdrServer.Api.Handlers.Plugins do
  @moduledoc """
  The `plugin.*` methods and `pane.link.activate`. Registry methods go to `Plugins.Install`
  and `Plugins.Registry`, actions and logs to `Plugins.Runtime` (`not_available` when it
  is not running); herdr's specific error code is `data.reason`. The rest answer
  `not_available` naming the M14 task that serves them.
  """

  alias HerdrServer.Api.Spec
  alias HerdrServer.Plugins.{Install, Registry, Runtime}

  @task5 ~w(plugin.pane.open plugin.pane.focus plugin.pane.close)
  @invalid ~w(invalid_plugin_id invalid_plugin_source invalid_plugin_path ambiguous_plugin_action)

  @spec handle(String.t(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def handle("plugin.list", p) do
    plugins =
      for pl <- Registry.plugins(), p[:plugin_id] in [nil, pl["plugin_id"]], do: public(pl)

    {:ok, %{type: "plugin_list", plugins: plugins}}
  end

  # ponytail: runs in the API connection process (git and the build can take minutes); two
  # reloads of this module during an install kill it mid-way. Move to a Task if that bites.
  def handle("plugin.install", p),
    do: info(Install.install(p.source, p[:ref], p[:yes] == true))

  def handle("plugin.link", p), do: info(Install.link(p.path, p[:enabled] != false))
  def handle("plugin.enable", p), do: info(Install.set_enabled(p.plugin_id, true))
  def handle("plugin.disable", p), do: info(Install.set_enabled(p.plugin_id, false))

  def handle("plugin.uninstall", p) do
    with {:ok, id} <- Install.uninstall(p.target) |> err(),
         do: {:ok, %{type: "plugin_removed", plugin_id: id}}
  end

  def handle("plugin.config_dir", p) do
    with {:ok, path} <- Install.config_dir(p.plugin_id) |> err(),
         do: {:ok, %{type: "plugin_dir", path: path}}
  end

  def handle("plugin.action.list", p),
    do: {:ok, %{type: "plugin_action_list", actions: Runtime.actions(p[:plugin_id])}}

  def handle("plugin.action.invoke", p) do
    with :ok <- running(),
         {:ok, r} <-
           Runtime.invoke(p.action_id, p[:plugin_id], p[:context] || %{}, "api") |> err(),
         do: {:ok, Map.put(r, :type, "plugin_action_invoked")}
  end

  def handle("plugin.log.list", p) do
    with :ok <- running(),
         do: {:ok, %{type: "plugin_log_list", logs: Runtime.logs(p[:plugin_id], p[:limit] || 50)}}
  end

  def handle(method, _params),
    do:
      {:error, :not_available, "#{method} is not served yet",
       %{requires: "M14 task #{task(method)}"}}

  defp task(m) when m in @task5, do: 5
  defp task("pane.link.activate"), do: 6

  defp running,
    do:
      if(Runtime.running?(),
        do: :ok,
        else:
          {:error, :not_available, "plugins are not running", %{reason: "plugins_not_running"}}
      )

  defp info(r),
    do: with({:ok, pl} <- err(r), do: {:ok, %{type: "plugin_info", plugin: public(pl)}})

  defp err({:error, reason, msg, preview}),
    do: {:error, :failed, msg, %{reason: reason, preview: preview}}

  defp err({:error, reason, msg}), do: {:error, code(reason), msg, %{reason: reason}}
  defp err(ok), do: ok

  defp code(r) when r in ~w(plugin_not_found plugin_action_not_found), do: :not_found
  defp code(r) when r in @invalid, do: :invalid_params
  defp code(_), do: :failed

  # the API `plugin` object: only its declared fields
  defp public(pl), do: Map.take(pl, Enum.map(Spec.objects()["plugin"], & &1.name))
end
