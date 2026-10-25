defmodule HerdrServer.App.CustomCommands do
  @moduledoc """
  herdr's custom commands (`[[keys.command]]`, parsed by `HerdrServer.Config` into
  `ui.custom_commands`). A command's key is bound to `{__MODULE__, :run, [index]}`.

  `run/2` by type:

    * `"shell"`: `{:custom_command, cmd, env, pane}`; the Store runs `exec/3` in a task,
      off the Store: it reads the pane's cwd, runs `/bin/sh -c cmd` there and logs the
      first 200 bytes of output on a non-zero exit (the rest is dropped as it arrives).
    * `"pane"`: splits the focused pane side by side; the new pane runs `/bin/sh -c cmd`
      in the focused pane's cwd.
    * `"plugin_action"`: the plugin keybind `HerdrServer.Plugins.Keybind.mfa/1` names.
    * `"popup"`: opens `App.Modal.Popup` (`width` / `height` as herdr's config values)
      running `/bin/sh -c cmd` in the focused pane's cwd, with no pane identity; a bad
      size, an open popup or a too small area is a warning notice.

  `env` is `HERDR_LIVE_BIN` (when the VM has it), `HERDR_LIVE_API` (the API socket),
  `HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID` (`p<n>`) and
  `HERDR_ACTIVE_PANE_CWD` (when known), as `{name, value}`. The pane cwd is read from
  the pty (`Persist.Facts.cwd/1`: an ETS lookup and one bounded NIF call).
  """

  require Logger

  defmodule Excerpt do
    @moduledoc "A `Collectable` that keeps the first 200 bytes and drops the rest."
    defstruct bin: ""
    @type t :: %__MODULE__{bin: binary}

    @doc "The kept bytes cut to a valid UTF-8 prefix."
    @spec text(t) :: binary
    def text(%__MODULE__{bin: bin}), do: valid(bin, 3)

    defp valid(bin, n) do
      cond do
        String.valid?(bin) -> bin
        n == 0 -> String.replace_invalid(bin)
        true -> valid(binary_part(bin, 0, byte_size(bin) - 1), n - 1)
      end
    end

    defimpl Collectable do
      @max 200
      def into(e), do: {e, &collect/2}

      defp collect(%{bin: b} = e, {:cont, x}) when byte_size(b) < @max,
        do: %{e | bin: b <> binary_part(x, 0, min(byte_size(x), @max - byte_size(b)))}

      defp collect(e, {:cont, _}), do: e
      defp collect(e, :done), do: e
      defp collect(_e, :halt), do: :ok
    end
  end

  alias HerdrServer.Api.{Ids, SocketPath}
  alias HerdrServer.App.{Actions, Commands}
  alias HerdrServer.App.CustomCommands.Excerpt
  alias HerdrServer.App.Modal.Popup
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
      %{type: "popup"} = c -> popup(app, c)
      %{type: type, command: cmd} -> run(app, type, cmd)
    end
  end

  defp run(app, "shell", cmd), do: {app, [{:custom_command, cmd, env(app), app.focus.pane}]}

  defp run(app, "pane", cmd) do
    # the one impure read in the Store: the spawn needs the cwd now
    {env, cwd} = with_cwd(env(app), app.focus.pane)

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

  # herdr's spawn_popup_shell_command: the focused pane's cwd, no pane identity
  defp popup(app, %{command: cmd} = c) do
    with {:ok, width} <- Popup.parse(Map.get(c, :width)),
         {:ok, height} <- Popup.parse(Map.get(c, :height)),
         id = app.session.next_id,
         {:ok, app, size} <-
           Popup.open(put_in(app.session.next_id, id + 1), id, %{width: width, height: height}) do
      {env, cwd} = with_cwd(env(app), app.focus.pane)

      opts = %{
        cwd: cwd,
        replay: nil,
        cmd: "/bin/sh",
        args: ["-c", cmd],
        env: env,
        identity: false
      }

      {app, [{:spawn, id, size, opts}]}
    else
      {:error, why} -> notice(app, "popup: #{why}")
    end
  end

  @doc "The command environment for `app`'s focused pane, without its cwd (see moduledoc)."
  @spec env(map) :: [{binary, binary}]
  def env(app) do
    pane = app.focus.pane
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

    if(bin in [nil, ""], do: [], else: [{"HERDR_LIVE_BIN", bin}]) ++
      [{"HERDR_LIVE_API", SocketPath.path()}] ++ place
  end

  defp with_cwd(env, pane) do
    case pane && Facts.cwd(pane) do
      nil -> {env, nil}
      cwd -> {env ++ [{"HERDR_ACTIVE_PANE_CWD", cwd}], cwd}
    end
  end

  @doc """
  Off the Store: runs a shell command for pane `pane` (nil: none) and waits for it. The
  output is collected into an `Excerpt` (bounded), logged on a non-zero exit.
  """
  @spec exec(binary, [{binary, binary}], pos_integer | nil) :: :ok
  def exec(cmd, env, pane) do
    {env, cwd} = with_cwd(env, pane)
    opts = [env: env, stderr_to_stdout: true, into: %Excerpt{}]
    opts = if cwd && File.dir?(cwd), do: [cd: cwd] ++ opts, else: opts

    case System.cmd("/bin/sh", ["-c", cmd], opts) do
      {_, 0} ->
        :ok

      {out, code} ->
        Logger.warning("custom command exited #{code}: #{inspect(cmd)}: #{Excerpt.text(out)}")
    end
  end

  defp notice(app, text), do: {app, [{:notice, %{level: :warning, text: text}}]}
end
