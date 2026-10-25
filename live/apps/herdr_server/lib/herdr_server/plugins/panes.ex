defmodule HerdrServer.Plugins.Panes do
  @moduledoc """
  Plugin panes (herdr's `plugin.pane.open`): a manifest `[[panes]]` entry run as a pane's
  pty child. `spec/2` checks the request against the registry and a snapshot of the app
  and builds the launch spec; `open/2` is the `Store.request/1` command that places it.
  `split` splits the target pane; `tab`, `overlay` and `zoomed` open a new tab in the
  target workspace (herdr-live has no overlay or zoom; a tab is the nearest full-area
  placement). `popup` is not available (M17). The pane's meta carries `:name` (the entry's
  title) and `:plugin` (`%{"plugin_id", "entrypoint"}`, plain data); persistence does not
  record `:plugin`, since a restored pane runs `$SHELL`, not the plugin command.
  """

  alias HerdrServer.App.Commands
  alias HerdrServer.Plugins.{Command, Context, Env, Manifest, Paths, Registry}

  # the Store sets these per pane, last
  @store_env ~w(HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID)

  @type error :: {:error, atom(), String.t(), map()}

  @doc "The launch spec for API params `p` against `app`, or an API error."
  @spec spec(map(), map()) :: {:ok, map()} | error()
  def spec(p, app) do
    with {:ok, pl} <- plugin(p.plugin_id),
         {:ok, entry} <- entry(pl, p.entrypoint),
         placement = p[:placement] || entry["placement"],
         :ok <- placeable(placement, p),
         {:ok, caller} <- caller_env(p[:env] || %{}),
         {:ok, ws, target} <- target(app, placement, p),
         {:ok, [cmd | args]} <- command(entry["command"], pl["plugin_root"]),
         :ok <- user_dirs(pl["plugin_id"]) do
      cwd = p[:cwd] || pl["plugin_root"]
      ctx = Context.build(app, target, "plugin-pane")
      auth = Env.for_command(pl, ctx, %{entrypoint: entry["id"]})

      # PWD defaults to the cwd (herdr); the pty env cannot unset, so nil entries go
      env =
        Env.merge(Map.put_new(caller, "PWD", cwd), auth)
        |> Enum.reject(fn {k, v} -> v == nil or k in @store_env end)

      {:ok,
       %{
         plugin_id: pl["plugin_id"],
         entrypoint: entry["id"],
         title: entry["title"],
         placement: placement,
         workspace: ws,
         target_pane: target,
         direction: p[:direction] || "right",
         focus: Map.get(p, :focus, true),
         cwd: cwd,
         cmd: cmd,
         args: args,
         env: env
       }}
    end
  end

  @doc "Places the pane `spec` describes; a vanished target changes nothing."
  @spec open(map(), map()) :: {map(), list()}
  def open(app, spec) do
    {app, fx} = place(app, spec)

    case Enum.find(fx, &match?({:spawn, _, _}, &1)) do
      {:spawn, id, size} = old ->
        meta = %{
          name: spec.title,
          plugin: %{"plugin_id" => spec.plugin_id, "entrypoint" => spec.entrypoint}
        }

        app = update_in(app.session.panes[id], &Map.merge(&1, meta))
        {app, _} = if spec.focus, do: Commands.focus_pane(app, id), else: {app, []}
        opts = %{cwd: spec.cwd, replay: nil, cmd: spec.cmd, args: spec.args, env: spec.env}
        {app, Enum.map(fx, &if(&1 == old, do: {:spawn, id, size, opts}, else: &1))}

      nil ->
        {app, fx}
    end
  end

  @doc "True when pane `id` of `app` is a plugin pane."
  @spec plugin_pane?(map() | nil, integer()) :: boolean()
  def plugin_pane?(nil, _id), do: false
  def plugin_pane?(app, id), do: match?(%{plugin: %{}}, app.session.panes[id])

  defp place(app, %{placement: "split"} = s) do
    dir = if s.direction == "down", do: :vertical, else: :horizontal
    Commands.split_pane(app, s.target_pane, dir, 0.5, false)
  end

  defp place(app, s), do: Commands.create_tab(app, s.workspace, nil, false)

  # --- checks ---

  defp plugin(id) do
    case Registry.find(id) do
      :error ->
        err(:not_found, "plugin_not_found", "plugin not found")

      {:ok, %{"error" => e}} when e != nil ->
        err(:failed, "plugin_manifest_unavailable", "plugin #{id} manifest is unavailable: #{e}")

      {:ok, %{"enabled" => true} = pl} ->
        {:ok, pl}

      {:ok, _} ->
        err(:failed, "plugin_disabled", "plugin #{id} is disabled")
    end
  end

  defp entry(pl, id) do
    case Enum.find(pl["panes"] || [], &(&1["id"] == id)) do
      nil ->
        err(:not_found, "plugin_pane_not_found", "plugin pane entrypoint '#{id}' not found")

      e ->
        if Manifest.platform_ok?(e["platforms"], pl["platforms"]),
          do: {:ok, e},
          else:
            err(
              :failed,
              "platform_unsupported",
              "plugin pane does not support the current platform"
            )
    end
  end

  defp placeable("popup", _p),
    do:
      {:error, :not_available, "popup plugin panes are not served yet", %{requires: "M17 popups"}}

  defp placeable(_placement, p) when is_map_key(p, :width) or is_map_key(p, :height),
    do:
      err(
        :invalid_params,
        "invalid_params",
        "width and height are only supported when placement is popup"
      )

  defp placeable(_placement, _p), do: :ok

  defp caller_env(env) do
    bad =
      Enum.find(env, fn {k, v} ->
        k == "" or String.contains?(k, ["=", <<0>>]) or String.contains?(v, <<0>>)
      end)

    if bad,
      do: err(:invalid_params, "invalid_env", "invalid env entry #{inspect(elem(bad, 0))}"),
      else: {:ok, env}
  end

  # {:ok, workspace, pane}: a tab goes in the workspace (default the active one) and runs
  # against its focused pane; a split targets the pane (default the workspace's focused one)
  defp target(app, "split", p) do
    pane =
      p[:target_pane_id] ||
        if(p[:workspace_id],
          do: Context.target_pane(app, {:workspace, p.workspace_id}),
          else: app.focus.pane
        )

    case pane && Commands.locate(app, pane) do
      {w, _t} -> {:ok, w, pane}
      nil -> err(:not_found, "pane_not_found", "pane #{inspect(pane)} not found")
    end
  end

  defp target(app, _placement, p) do
    w = p[:workspace_id] || app.session.active_workspace

    case Context.target_pane(app, {:workspace, w}) do
      nil -> err(:not_found, "workspace_not_found", "workspace not found")
      pane -> {:ok, w, pane}
    end
  end

  defp command([cmd | args], root) do
    case Command.resolve(cmd, root) do
      nil -> err(:failed, "plugin_pane_open_failed", "command not found: #{cmd}")
      exe -> {:ok, [exe | args]}
    end
  end

  defp user_dirs(id) do
    case Paths.ensure_user_dirs(id) do
      :ok -> :ok
      e -> err(:failed, "plugin_user_dir_create_failed", inspect(e))
    end
  end

  defp err(code, reason, msg), do: {:error, code, msg, %{reason: reason}}
end
