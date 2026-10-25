defmodule HerdrServer.App.CustomCommands do
  @moduledoc """
  herdr's custom commands (`[[keys.command]]`, parsed by `HerdrServer.Config` into
  `ui.custom_commands`). A command's key is bound to `{__MODULE__, :run, [index]}`.

  `run/2` by type:

    * `"shell"`: `{:custom_command, cmd, env, cwd}`; the Store runs `/bin/sh -c cmd` in a
      task (output logged on a non-zero exit).
    * `"pane"`: splits the focused pane side by side; the new pane runs `/bin/sh -c cmd`
      in the focused pane's cwd.
    * `"plugin_action"`: the plugin keybind `HerdrServer.Plugins.Keybind.mfa/1` names.
    * `"popup"`: a notice until popups land.

  `env` is `HERDR_LIVE_BIN` (when the VM has it), `HERDR_LIVE_API` (the API socket),
  `HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID` (`p<n>`) and
  `HERDR_ACTIVE_PANE_CWD` (when known), as `{name, value}`. `cwd` is the focused pane's
  cwd or nil. The pane cwd is read from the pty (`Persist.Facts.cwd/1`: an ETS lookup and
  one bounded NIF call), once per run.
  """

  alias HerdrServer.Api.{Ids, SocketPath}
  alias HerdrServer.App.{Actions, Commands}
  alias HerdrServer.Persist.Facts
  alias HerdrServer.Plugins.Keybind

  @type entry :: %{
          key: binary,
          command: binary,
          type: binary,
          description: binary | nil,
          width: term,
          height: term
        }

  @spec run(map, non_neg_integer) :: {map, [tuple]}
  def run(app, index) do
    case Enum.at(app.ui.custom_commands, index) do
      nil -> notice(app, "custom command #{index} is gone; reload the config")
      %{type: type, command: cmd} -> run(app, type, cmd)
    end
  end

  defp run(app, "shell", cmd) do
    {env, cwd} = env(app)
    {app, [{:custom_command, cmd, env, cwd}]}
  end

  defp run(app, "pane", cmd) do
    {env, cwd} = env(app)

    case Actions.split(app, :horizontal) do
      {app, [{:spawn, id, size}]} ->
        {app,
         [
           {:spawn, id, size,
            %{cwd: cwd, replay: nil, cmd: "/bin/sh", args: ["-c", cmd], env: env}}
         ]}

      other ->
        other
    end
  end

  defp run(app, "plugin_action", cmd) do
    {m, f, a} = Keybind.mfa(cmd)
    apply(m, f, [app | a])
  end

  defp run(app, "popup", _cmd), do: notice(app, "popup commands are not supported yet")

  @doc "The command environment and cwd for `app`'s focused pane (see moduledoc)."
  @spec env(map) :: {[{binary, binary}], binary | nil}
  def env(app) do
    pane = app.focus.pane
    cwd = pane && Facts.cwd(pane)
    bin = System.get_env("HERDR_LIVE_BIN")

    place =
      case pane && Commands.locate(app, pane) do
        {w, t} ->
          [
            {"HERDR_ACTIVE_WORKSPACE_ID", Ids.workspace(w)},
            {"HERDR_ACTIVE_TAB_ID", Ids.tab(w, t)},
            {"HERDR_ACTIVE_PANE_ID", Ids.pane(pane)}
          ]

        nil ->
          []
      end

    env =
      if(bin in [nil, ""], do: [], else: [{"HERDR_LIVE_BIN", bin}]) ++
        [{"HERDR_LIVE_API", SocketPath.path()}] ++
        place ++ if(cwd, do: [{"HERDR_ACTIVE_PANE_CWD", cwd}], else: [])

    {env, cwd}
  end

  defp notice(app, text), do: {app, [{:notice, %{level: :warning, text: text}}]}
end
