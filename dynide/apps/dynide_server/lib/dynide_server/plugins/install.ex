defmodule DynideServer.Plugins.Install do
  @moduledoc """
  Registry changes (herdr's semantics): link a local directory (no build), install from
  GitHub shorthand or a local copy (preview, confirm, build), uninstall (unregister only,
  files kept), enable/disable, and the plugin config dir. Errors are
  `{:error, reason, message}` with herdr's reason strings.

  An install stages the checkout under `<config>/plugins/.staging`, validates its manifest,
  answers `confirmation_required` with a preview unless confirmed, then moves it to a fresh
  `Paths.installations_dir(id)/<n>` and runs the build commands there.

  An update (herdr's `plugin update`) re-clones a GitHub install at its recorded ref (or a
  new one), checks the plugin id is unchanged, previews like an install, then places it
  in a fresh installation dir; the old dir and registry entry stay until that succeeds.
  """

  alias DynideServer.Plugins.{Command, Manifest, Paths, Registry}

  @build_timeout_ms 600_000
  @id_re ~r/\A[A-Za-z0-9.:_-]{1,120}\z/
  @segment_re ~r/\A[A-Za-z0-9._-]+\z/

  @type error :: {:error, String.t(), String.t()}

  @spec link(Path.t(), boolean()) :: {:ok, Registry.plugin()} | error()
  def link(path, enabled?) do
    # the CLI makes relative paths absolute against the user's cwd; never guess here
    with :ok <- absolute(path, "invalid_plugin_path"),
         {:ok, m} <- Manifest.load(path),
         :ok <- user_dirs(m["plugin_id"]),
         :ok <- register(m, enabled?, %{"kind" => "local"}),
         do: found(m["plugin_id"])
  end

  @spec install(String.t(), String.t() | nil, boolean()) ::
          {:ok, Registry.plugin()} | error() | {:error, String.t(), String.t(), map()}
  def install(source, ref, yes?) do
    with {:ok, src} <- parse(source, ref) do
      stage = stage_dir()

      try do
        staged(src, ref, yes?, stage)
      after
        File.rm_rf(stage)
      end
    end
  end

  @type update_result :: %{updated: [Registry.plugin()], up_to_date: [String.t()]}

  @doc """
  herdr's `plugin update`: one plugin (id or `owner/repo[/subdir]`) or, for nil, every
  GitHub install. As herdr (`src/cli/plugin.rs` plugin_update), every plugin is tried: one
  that fails does not stop the rest, and when any failed (updating all) the answer is
  `plugin_update_failed` carrying what was updated, what was current and each failure.
  """
  @spec update(String.t() | nil, String.t() | nil, boolean()) ::
          {:ok, update_result()}
          | error()
          | {:error, String.t(), String.t(), [map()]}
          | {:error, String.t(), String.t(), map()}
  def update(target, ref, yes?) do
    with :ok <- valid_ref(ref),
         :ok <- ref_needs_target(target, ref),
         {:ok, plugins} <- update_targets(target) do
      acc = %{updated: [], up_to_date: [], previews: [], failed: []}
      plugins |> Enum.reduce(acc, &update_step(&1, ref, yes?, &2)) |> update_answer(target)
    end
  end

  defp ref_needs_target(nil, ref) when is_binary(ref),
    do: {:error, "invalid_plugin_source", "--ref needs a plugin to update"}

  defp ref_needs_target(_target, _ref), do: :ok

  defp update_targets(nil),
    do: {:ok, Enum.filter(Registry.plugins(), &(&1["source"]["kind"] == "github"))}

  defp update_targets(target) do
    case lookup(target) do
      {:ok, %{"source" => %{"kind" => "github"}} = p} ->
        {:ok, [p]}

      {:ok, _} ->
        {:error, "not_applicable", "plugin is locally linked and cannot be updated: #{target}"}

      e ->
        e
    end
  end

  defp update_step(p, ref, yes?, acc) do
    case update_one(p, ref, yes?) do
      {:ok, new} -> %{acc | updated: [new | acc.updated]}
      :up_to_date -> %{acc | up_to_date: [p["plugin_id"] | acc.up_to_date]}
      {:preview, pr} -> %{acc | previews: [pr | acc.previews]}
      {:error, _, _} = e -> %{acc | failed: [{p["plugin_id"], e} | acc.failed]}
    end
  end

  # one named plugin that failed answers its own error, as an install would
  defp update_answer(%{failed: [{_id, e}]}, target) when target != nil, do: e

  defp update_answer(%{failed: [_ | _]} = acc, _target) do
    failed =
      for {id, {:error, reason, msg}} <- Enum.reverse(acc.failed),
          do: %{plugin_id: id, reason: reason, message: msg}

    {:error, "plugin_update_failed",
     "error updating #{Enum.map_join(failed, ", ", & &1.plugin_id)}: see data.failed",
     %{
       updated: Enum.reverse(acc.updated),
       up_to_date: Enum.reverse(acc.up_to_date),
       failed: failed,
       preview: Enum.reverse(acc.previews)
     }}
  end

  defp update_answer(%{previews: [_ | _]} = acc, _target),
    do:
      {:error, "confirmation_required",
       "plugin update needs confirmation: review data.preview, then re-run with --yes",
       Enum.reverse(acc.previews)}

  defp update_answer(acc, _target),
    do: {:ok, %{updated: Enum.reverse(acc.updated), up_to_date: Enum.reverse(acc.up_to_date)}}

  defp update_one(%{"plugin_id" => id, "source" => old} = p, ref, yes?) do
    src = {:github, old["owner"], old["repo"], old["subdir"]}
    ref = ref || old["requested_ref"]
    stage = stage_dir()

    try do
      with {:ok, source} <- fetch(src, ref, stage),
           :ok <- contained(stage, src),
           {:ok, m} <- Manifest.load(root(stage, src)),
           :ok <- same_id(m["plugin_id"], id) do
        cond do
          source["resolved_commit"] == old["resolved_commit"] and ref == old["requested_ref"] ->
            :up_to_date

          yes? ->
            place(id, src, source, stage, p["enabled"])

          true ->
            {:preview, preview(m, source)}
        end
      end
    after
      File.rm_rf(stage)
    end
  end

  defp same_id(id, id), do: :ok

  defp same_id(new, id),
    do:
      {:error, "plugin_update_id_changed",
       "update source now contains plugin #{new}, expected #{id}"}

  @spec uninstall(String.t()) :: {:ok, String.t()} | error()
  def uninstall(target) do
    with {:ok, %{"plugin_id" => id}} <- lookup(target),
         :ok <- save(fn es -> Enum.reject(es, &(&1["plugin_id"] == id)) end),
         do: {:ok, id}
  end

  @spec set_enabled(String.t(), boolean()) :: {:ok, Registry.plugin()} | error()
  def set_enabled(id, enabled?) do
    flip = fn e -> if e["plugin_id"] == id, do: %{e | "enabled" => enabled?}, else: e end

    with {:ok, _} <- found(id),
         :ok <- save(&Enum.map(&1, flip)),
         do: found(id)
  end

  @doc "herdr's `plugin config-dir`: the dir (created), registered or not."
  @spec config_dir(String.t()) :: {:ok, Path.t()} | error()
  def config_dir(id) do
    with :ok <- valid_id(id), :ok <- user_dirs(id), do: {:ok, Paths.plugin_config_dir(id)}
  end

  # --- install ---

  defp stage_dir,
    do:
      Path.join([
        Paths.config_dir(),
        "plugins",
        ".staging",
        "#{System.unique_integer([:positive])}"
      ])

  defp valid_ref(ref) when is_binary(ref) do
    if String.starts_with?(ref, "-"),
      do: {:error, "invalid_plugin_source", "invalid ref #{inspect(ref)}"},
      else: :ok
  end

  defp valid_ref(nil), do: :ok

  defp staged(src, ref, yes?, stage) do
    with {:ok, source} <- fetch(src, ref, stage),
         :ok <- contained(stage, src),
         {:ok, m} <- Manifest.load(root(stage, src)),
         :ok <- not_linked(m["plugin_id"]) do
      if yes?,
        do: place(m["plugin_id"], src, source, stage, true),
        else:
          {:error, "confirmation_required",
           "plugin install needs confirmation: review data.preview, then re-run with --yes",
           preview(m, source)}
    end
  end

  defp place(id, src, source, stage, enabled?) do
    case claim(id, stage) do
      {:ok, dest} ->
        with {:ok, m} <- Manifest.load(root(dest, src)),
             :ok <- user_dirs(id),
             :ok <- build(m),
             {:ok, ^m} <- Manifest.load(root(dest, src)),
             :ok <- register(m, enabled?, Map.put(source, "managed_path", dest)) do
          found(id)
        else
          e ->
            # only the dir this install renamed into place
            File.rm_rf(dest)
            place_error(e, dest)
        end

      {:error, e, dest} ->
        place_error({:error, e}, dest)
    end
  end

  # picks the next installation dir and renames the stage onto it, one install per id at a time
  defp claim(id, stage) do
    :global.trans({{__MODULE__, id}, self()}, fn ->
      dest = next_installation(id)

      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.rename(stage, dest),
           do: {:ok, dest},
           else: ({:error, e} -> {:error, e, dest})
    end)
  end

  # the manifest (and a GitHub subdir) must stay inside the checkout once symlinks resolve
  defp contained(stage, src) do
    rel = root(stage, src) |> Path.join("herdr-plugin.toml") |> Path.relative_to(stage)

    if :filelib.safe_relative_path(rel, stage) == :unsafe,
      do: {:error, "invalid_plugin_source", "#{rel} resolves outside the plugin checkout"},
      else: :ok
  end

  defp place_error({:ok, _changed}, dest),
    do:
      {:error, "plugin_manifest_changed_by_build",
       "the build changed herdr-plugin.toml under #{dest} after the preview; aborting install"}

  defp place_error({:error, e}, dest) when is_atom(e),
    do: {:error, "plugin_install_failed", "#{dest}: #{:file.format_error(e)}"}

  defp place_error(e, _dest), do: e

  defp fetch({:local, dir}, _ref, stage) do
    case File.ls(dir) do
      {:ok, names} ->
        File.mkdir_p!(stage)

        with :ok <- copy(dir, names -- [".git"], stage),
             do: {:ok, %{"kind" => "local", "path" => dir}}

      {:error, e} ->
        {:error, "plugin_manifest_not_found", "#{dir}: #{:file.format_error(e)}"}
    end
  end

  defp fetch({:github, owner, repo, subdir}, ref, stage) do
    base = Application.get_env(:dynide_server, :plugins, [])[:git_base] || "https://github.com/"
    branch = if ref, do: ["--branch=" <> ref], else: []
    File.mkdir_p!(Path.dirname(stage))

    with :ok <-
           git(
             ["clone", "--depth", "1"] ++ branch ++ [base <> owner <> "/" <> repo, stage],
             Path.dirname(stage)
           ),
         {:ok, commit} <- git_out(["rev-parse", "HEAD"], stage) do
      {:ok,
       %{
         "kind" => "github",
         "owner" => owner,
         "repo" => repo,
         "subdir" => subdir,
         "requested_ref" => ref,
         "resolved_commit" => commit,
         "installed_unix_ms" => System.os_time(:millisecond)
       }}
    end
  end

  defp copy(dir, names, stage) do
    Enum.reduce_while(names, :ok, fn n, :ok ->
      case File.cp_r(Path.join(dir, n), Path.join(stage, n)) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, e, f} ->
          {:halt, {:error, "plugin_copy_failed", "#{f}: #{:file.format_error(e)}"}}
      end
    end)
  end

  defp git(args, cwd), do: with({:ok, _} <- git_out(args, cwd), do: :ok)

  defp git_out(args, cwd) do
    case Command.run(["git" | args], cwd, [{"GIT_TERMINAL_PROMPT", "0"}],
           timeout_ms: @build_timeout_ms
         ) do
      %{exit_code: 0, stdout: out} ->
        {:ok, String.trim(out)}

      r ->
        {:error, "plugin_git_failed",
         "git #{Enum.join(args, " ")}: #{r.error || "exit #{r.exit_code}"}\n#{r.stderr}"}
    end
  end

  defp root(dir, {:github, _, _, sub}) when is_binary(sub), do: Path.join(dir, sub)
  defp root(dir, _src), do: dir

  defp not_linked(id) do
    case Registry.find(id) do
      {:ok, %{"plugin_id" => ^id, "source" => s}} when not is_map_key(s, "managed_path") ->
        {:error, "plugin_install_over_link",
         "plugin #{id} is linked from a local path; uninstall it before installing"}

      _ ->
        :ok
    end
  end

  defp preview(m, source) do
    %{
      plugin_id: m["plugin_id"],
      name: m["name"],
      version: m["version"],
      source: source,
      build: builds(m),
      startup: Enum.map(m["startup"], & &1["command"]),
      actions: m["actions"],
      events: m["events"],
      panes: m["panes"],
      link_handlers: m["link_handlers"]
    }
  end

  defp builds(m),
    do:
      for(
        b <- m["build"],
        Manifest.platform_ok?(b["platforms"], m["platforms"]),
        do: b["command"]
      )

  # in order, in the plugin root, with no herdr runtime or plugin env (herdr's scrub)
  defp build(m) do
    env = for {k, _} <- System.get_env(), String.starts_with?(k, "HERDR_"), do: {k, nil}
    cmds = builds(m)

    cmds
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {argv, i}, :ok ->
      opts = [timeout_ms: @build_timeout_ms, tmp_dir: Paths.plugin_state_dir(m["plugin_id"])]

      case Command.run(argv, m["plugin_root"], env, opts) do
        %{exit_code: 0} -> {:cont, :ok}
        r -> {:halt, {:error, "plugin_build_failed", build_failure(m, i, length(cmds), argv, r)}}
      end
    end)
  end

  defp build_failure(m, i, n, argv, r) do
    status = if r.error, do: "error: #{r.error}", else: "status: #{r.exit_code}"

    [
      "plugin build failed",
      "  plugin: #{m["plugin_id"]}",
      "  build: #{i}/#{n}",
      "  cwd: #{m["plugin_root"]}",
      "  command: #{Enum.join(argv, " ")}",
      "  " <> status
    ]
    |> Kernel.++(section("stderr", r.stderr) ++ section("stdout", r.stdout))
    |> Enum.join("\n")
  end

  defp section(label, text) do
    case String.trim_trailing(text) do
      "" -> []
      t -> ["", label <> ":", t]
    end
  end

  # ponytail: older installation dirs are kept (herdr keeps them for running commands);
  # add herdr's lease cleanup when disk use shows
  defp next_installation(id) do
    dir = Paths.installations_dir(id)

    names =
      case File.ls(dir) do
        {:ok, l} -> l
        {:error, _} -> []
      end

    taken = for n <- names, {i, ""} <- [Integer.parse(n)], do: i
    Path.join(dir, Integer.to_string(Enum.max(taken, fn -> 0 end) + 1))
  end

  # --- sources ---

  defp parse(source, ref) do
    with :ok <- valid_ref(ref), do: parse_source(source, ref)
  end

  defp parse_source(source, ref) do
    cond do
      String.starts_with?(source, ["/", "./", "../", "~"]) ->
        cond do
          ref ->
            {:error, "invalid_plugin_source", "--ref applies to GitHub sources only"}

          absolute(source, "invalid_plugin_source") != :ok ->
            absolute(source, "invalid_plugin_source")

          true ->
            {:ok, {:local, source}}
        end

      String.contains?(source, ":") ->
        {:error, "invalid_plugin_source",
         "plugin install accepts only owner/repo[/subdir] shorthand or a local directory"}

      true ->
        github(String.split(source, "/"))
    end
  end

  defp github([owner, repo | sub]) do
    bad = Enum.find([owner, repo | sub], &(&1 in ["", ".", ".."] or not (&1 =~ @segment_re)))

    if bad,
      do: {:error, "invalid_plugin_source", "invalid GitHub source segment: #{inspect(bad)}"},
      else: {:ok, {:github, owner, repo, if(sub == [], do: nil, else: Enum.join(sub, "/"))}}
  end

  defp github(_),
    do:
      {:error, "invalid_plugin_source",
       "usage: plugin install <owner/repo[/subdir]|./dir> [--ref REF] [--yes]"}

  # --- registry ---

  defp register(m, enabled?, source) do
    entry = %{
      "plugin_id" => m["plugin_id"],
      "plugin_root" => m["plugin_root"],
      "manifest_path" => m["manifest_path"],
      "enabled" => enabled?,
      "source" => source
    }

    save(fn es -> [entry | Enum.reject(es, &(&1["plugin_id"] == entry["plugin_id"]))] end)
  end

  defp save(fun) do
    case Registry.update(fun) do
      {:ok, _} -> :ok
      {:error, e} -> {:error, "plugin_registry_save_failed", "#{Paths.registry()}: #{inspect(e)}"}
    end
  end

  defp lookup(target) do
    case Registry.find(target) do
      {:ok, p} -> {:ok, p}
      :error -> not_found()
    end
  end

  defp found(id) do
    case Registry.find(id) do
      {:ok, %{"plugin_id" => ^id} = p} -> {:ok, p}
      _ -> not_found()
    end
  end

  defp not_found, do: {:error, "plugin_not_found", "plugin not found"}

  defp absolute(path, reason) do
    if Path.type(path) == :absolute,
      do: :ok,
      else: {:error, reason, "local plugin paths must be absolute: #{path}"}
  end

  defp valid_id(id) do
    if id =~ @id_re and id not in [".", ".."],
      do: :ok,
      else:
        {:error, "invalid_plugin_id",
         "plugin id must be non-empty, <= 120 characters, and contain only ASCII letters, digits, colon, dot, underscore, or hyphen"}
  end

  defp user_dirs(id) do
    case Paths.ensure_user_dirs(id) do
      :ok ->
        :ok

      {:error, e} ->
        {:error, "plugin_user_dir_create_failed", :file.format_error(e) |> to_string()}
    end
  end
end
