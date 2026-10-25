defmodule HerdrServer.Plugins.Panes do
  @moduledoc """
  Plugin panes (herdr's `plugin.pane.open`): a manifest `[[panes]]` entry run as a pane's
  pty child. `spec/2` checks the request against the registry and a snapshot of the app
  and builds the launch spec; `open/2` is the `Store.request/1` command that places it.
  `split` splits the target pane; `tab` and `overlay` open a new tab in the target
  workspace, `zoomed` in the target pane's (herdr-live has no overlay or zoom; a tab is the
  nearest full-area placement). The pane's meta carries `:name` (the entry's
  title) and `:plugin` (`%{"plugin_id", "entrypoint"}`, plain data); persistence does not
  record `:plugin`, since a restored pane runs `$SHELL`, not the plugin command.

  `popup` (herdr's `open_plugin_popup_pane`) opens `App.Modal.Popup` over the active tab,
  titled with the entry's title and sized by the request's `width` / `height`, else the
  entry's (cells or `"N%"`). Like herdr it targets the active pane only (no
  `workspace_id`, `target_pane_id` or `direction`), refuses while a popup is open
  (`ui_busy`), runs with no pane identity and closes when its program exits. Its pane
  is not in `session.panes`, so it is not a `plugin_pane?/2`.
  """

  alias HerdrServer.App.Commands
  alias HerdrServer.App.Modal.Popup
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
         :ok <- popup_free(placement, app),
         {:ok, width} <- popup_size(placement, p[:width] || entry["width"]),
         {:ok, height} <- popup_size(placement, p[:height] || entry["height"]),
         {:ok, caller} <- caller_env(p[:env] || %{}),
         {:ok, ws, target} <- target(app, placement, p),
         {:ok, [cmd | args]} <- command(entry["command"], pl["plugin_root"]),
         :ok <- user_dirs(pl["plugin_id"]) do
      cwd = p[:cwd] || pl["plugin_root"]
      ctx = Context.build(app, target, "plugin-pane")
      auth = Env.for_command(pl, ctx, %{entrypoint: entry["id"]})

      # PWD defaults to the cwd (herdr)
      env = Env.merge(Map.put_new(caller, "PWD", cwd), auth) |> Enum.flat_map(&pty_env/1)

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
         width: width,
         height: height,
         cwd: cwd,
         cmd: cmd,
         args: args,
         env: env
       }}
    end
  end

  # the pty env cannot unset, so nil entries go, except the VM-only names, blanked
  # ("" reads as unset) so none is inherited
  defp pty_env({k, _}) when k in @store_env, do: []
  defp pty_env({k, nil}), do: if(k in Env.vm_only(), do: [{k, ""}], else: [])
  defp pty_env(kv), do: [kv]

  @doc "Places the pane `spec` describes; a vanished target changes nothing."
  @spec open(map(), map()) :: {map(), list()}
  def open(app, %{placement: "popup"} = spec) do
    size = %{width: spec.width, height: spec.height, title: spec.title}

    case Popup.open(app, size) do
      {:ok, app2, id, size} ->
        opts = %{
          cwd: spec.cwd,
          replay: nil,
          cmd: spec.cmd,
          args: spec.args,
          env: spec.env,
          identity: false
        }

        {app2, [{:spawn, id, size, opts}]}

      {:error, why} ->
        {app, [{:notice, %{level: :warning, text: why}}]}
    end
  end

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

  defp placeable(placement, p)
       when placement != "popup" and (is_map_key(p, :width) or is_map_key(p, :height)),
       do:
         err(
           :invalid_params,
           "invalid_params",
           "width and height are only supported when placement is popup"
         )

  # herdr's per-placement target params
  defp placeable(placement, p)
       when placement in ["overlay", "popup"] and
              (is_map_key(p, :workspace_id) or is_map_key(p, :target_pane_id) or
                 is_map_key(p, :direction)),
       do:
         err(
           :invalid_params,
           "invalid_params",
           "overlay and popup plugin panes target the active pane"
         )

  defp placeable(placement, p)
       when placement in ["split", "zoomed"] and is_map_key(p, :workspace_id),
       do:
         err(
           :invalid_params,
           "invalid_params",
           "split and zoomed plugin panes target an existing pane; use target_pane_id"
         )

  defp placeable("tab", p) when is_map_key(p, :target_pane_id) or is_map_key(p, :direction),
    do:
      err(
        :invalid_params,
        "invalid_params",
        "tab plugin panes support workspace_id but not target_pane_id or direction"
      )

  defp placeable(_placement, _p), do: :ok

  defp popup_free("popup", app) do
    if Popup.find(app),
      do: err(:failed, "ui_busy", "a popup pane is already open"),
      else: :ok
  end

  defp popup_free(_placement, _app), do: :ok

  # API and manifest sizes are herdr's: integer cells or "N%"
  defp popup_size("popup", v) do
    case Popup.parse(v) do
      {:ok, size} -> {:ok, size}
      {:error, why} -> err(:invalid_params, "invalid_params", "popup size #{why}")
    end
  end

  defp popup_size(_placement, _v), do: {:ok, nil}

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
  # against its focused pane; split and zoomed target the pane (default the focused one)
  defp target(app, placement, p) when placement in ["split", "zoomed"] do
    pane = p[:target_pane_id] || app.focus.pane

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
