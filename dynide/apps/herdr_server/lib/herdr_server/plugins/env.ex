defmodule HerdrServer.Plugins.Env do
  @moduledoc """
  The environment herdr gives a plugin command (its contract, authoritative over any
  caller-supplied env). The rest of the env is the VM's, as herdr's plugins inherit the
  user's. Optional names without a value are `nil`, which unsets a value inherited from
  the VM's env (`Plugins.Command.run/4`'s env shape).
  """

  alias HerdrServer.Api.SocketPath
  alias HerdrServer.Plugins.Paths

  @type env :: [{String.t(), String.t() | nil}]

  @modifiers ~w(shift alt ctrl)

  # this VM's own handoff and launcher state (bin/herdr-live, config/runtime.exs): never a
  # plugin's, above all not the kernel handoff socket
  @vm_only ~w(HERDR_BROKER_SOCK HERDR_LIVE_GEN HERDR_LIVE_RUNTIME_DIR HERDR_LIVE_LOG
              HERDR_LIVE_HEADLESS HERDR_LIVE_TEST_ON_SAVE HERDR_LIVE_PERSIST
              HERDR_LIVE_STATE_DIR HERDR_LIVE_SESSION)

  @doc "`kind` holds any of `:action_id`, `:event`, `:event_json`, `:entrypoint`."
  @spec for_command(map(), map(), map()) :: env()
  def for_command(plugin, context, kind) do
    id = plugin["plugin_id"]
    socket = Path.expand(SocketPath.path())
    bin = env("HERDR_LIVE_BIN") || launcher()

    [
      {"HERDR_SOCKET_PATH", socket},
      {"HERDR_LIVE_API", socket},
      {"HERDR_BIN_PATH", bin},
      {"HERDR_LIVE_BIN", bin},
      {"HERDR_ENV", "1"},
      {"HERDR_PLUGIN_ID", id},
      {"HERDR_PLUGIN_ROOT", plugin["plugin_root"]},
      {"HERDR_PLUGIN_CONFIG_DIR", Paths.plugin_config_dir(id)},
      {"HERDR_PLUGIN_STATE_DIR", Paths.plugin_state_dir(id)},
      {"HERDR_PLUGIN_CONTEXT_JSON", JSON.encode!(context)},
      {"HERDR_WORKSPACE_ID", context["workspace_id"]},
      {"HERDR_TAB_ID", context["tab_id"]},
      {"HERDR_PANE_ID", context["focused_pane_id"]},
      {"HERDR_PLUGIN_ACTION_ID", kind[:action_id]},
      {"HERDR_PLUGIN_EVENT", kind[:event]},
      {"HERDR_PLUGIN_EVENT_JSON", kind[:event_json]},
      {"HERDR_PLUGIN_ENTRYPOINT_ID", kind[:entrypoint]},
      {"HERDR_PLUGIN_CLICKED_URL", context["clicked_url"]},
      {"HERDR_PLUGIN_LINK_HANDLER_ID", context["link_handler_id"]},
      {"HERDR_PLUGIN_CLICK_MODIFIERS", modifiers(context["click_modifiers"])}
    ] ++ Enum.map(@vm_only, &{&1, nil})
  end

  @doc "The VM-only names `for_command/3` unsets."
  @spec vm_only() :: [String.t()]
  def vm_only, do: @vm_only

  @doc "The caller's env with every authoritative name taken from `authoritative`."
  @spec merge(%{String.t() => String.t()}, env()) :: env()
  def merge(caller, authoritative) do
    names = MapSet.new(authoritative, &elem(&1, 0))
    Enum.reject(caller, fn {k, _} -> MapSet.member?(names, k) end) ++ authoritative
  end

  defp modifiers(list) when is_list(list) do
    case Enum.filter(@modifiers, &(&1 in list)) do
      [] -> nil
      held -> Enum.join(held, ",")
    end
  end

  defp modifiers(_), do: nil

  # a VM not started by bin/herdr-live: this checkout's launcher, found from the app's own
  # dir at runtime (dynide/_build/<env>/lib/herdr_server); an inherited HERDR_BIN_PATH may
  # be the real herdr's
  defp launcher,
    do: Path.expand("../../../../bin/herdr-live", Application.app_dir(:herdr_server))

  defp env(name), do: with(v when v not in [nil, ""] <- System.get_env(name), do: v)
end
