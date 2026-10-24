defmodule HerdrReload.Compiler do
  @moduledoc """
  Drives Mix's incremental compiler for one reload batch and reports what changed.

  Loading is left to the caller; Mix itself deletes the current code of every
  recompiled module, so new code autoloads from disk until the caller loads it.

  `changed` holds modules whose beam was rewritten with different bytes:
  byte-identical rewrites (a dependent recompiled to the same code) are not
  fan-out. `opts[:project_dir]` and `opts[:app]` run every Mix call inside that
  project instead of the current one.
  """

  alias HerdrReload.Loader
  alias Mix.Task.Compiler, as: MixCompiler

  require Logger

  @type cache :: %{module() => binary()}
  @type result :: %{
          changed: cache(),
          removed: [module()],
          previous: %{module() => binary() | nil},
          paths: %{module() => Path.t()},
          diagnostics: list(),
          mtimes: %{Path.t() => integer()}
        }

  @doc "Ebin dir per app of the project (umbrella children or the single app); deps excluded."
  @spec ebin_dirs(keyword()) :: %{atom() => Path.t()}
  def ebin_dirs(opts), do: in_project(opts, fn -> current_ebin_dirs() end)

  @doc "The project's Mix build path."
  @spec build_path(keyword()) :: Path.t()
  def build_path(opts), do: in_project(opts, &Mix.Project.build_path/0)

  @doc "Every beam in the project's ebin dirs, read from disk."
  @spec snapshot(keyword()) :: cache()
  def snapshot(opts), do: opts |> ebin_dirs() |> read_beams()

  @doc "Compiles `paths` incrementally; see the moduledoc for the result shape."
  @spec compile(cache(), [Path.t()], %{Path.t() => integer()}, keyword()) ::
          {:ok, result()} | {:error, list(), map()} | {:blocked, module(), [Loader.pid_info()]}
  def compile(cache, paths, mtimes, opts) do
    with :ok <- pre_sweep(cache, opts) do
      in_project(opts, fn -> run(cache, paths, mtimes) end)
    end
  end

  # Mix hard-purges old code of every module it recompiles (killing its
  # processes), so old code must be soft-purged first or the batch refused.
  defp pre_sweep(cache, opts) do
    purge_opts =
      [allowlist: Keyword.get(opts, :allowlist, [])] ++ Keyword.take(opts, [:retries, :retry_ms])

    Enum.reduce_while(cache, :ok, fn {mod, _}, :ok ->
      with true <- :erlang.check_old_code(mod),
           {:blocked, holders} <- Loader.purge_old(mod, purge_opts) do
        {:halt, {:blocked, mod, holders}}
      else
        _ -> {:cont, :ok}
      end
    end)
  end

  defp run(cache, paths, mtimes) do
    # Mix's staleness check has second resolution: back-date a path still at
    # the mtime it had when last compiled so a same-second edit is seen.
    for p <- paths, {:ok, m} <- [mtime(p)], m == mtimes[p], do: File.touch!(p, m - 1)

    loaded_before = for {m, _} <- cache, :code.is_loaded(m), into: MapSet.new(), do: m
    disk = disk_state(current_ebin_dirs())
    {status, diags} = compile_or_restore(cache, loaded_before, disk)
    mtimes = Enum.reduce(paths, mtimes, &update_mtime/2)

    case status do
      :error -> {:error, diags, mtimes}
      _ -> {:ok, diff(cache, disk) |> Map.merge(%{diagnostics: diags, mtimes: mtimes})}
    end
  end

  # try/after rather than a catch: a raise or exit inside Mix must restore too.
  defp compile_or_restore(cache, loaded_before, disk) do
    Process.put(:herdr_reload_compiled, false)

    try do
      res = mix_compile()
      Process.put(:herdr_reload_compiled, elem(res, 0) != :error)
      res
    after
      if !Process.delete(:herdr_reload_compiled), do: restore(cache, loaded_before, disk)
    end
  end

  # Fact 1 recipe, but through "compile.all": inside a recursing umbrella run
  # (`mix test`) the non-recursive "compile" task is redirected to the umbrella
  # root and returns :noop. Pruning is off: it would drop every code path the
  # compiled project does not own from the running VM.
  defp mix_compile do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      compilers = MixCompiler.compilers(Mix.Project.config())
      for t <- ["compile.all" | Enum.map(compilers, &"compile.#{&1}")], do: Mix.Task.reenable(t)

      "compile.all"
      |> Mix.Task.run(["--return-errors", "--no-prune-code-paths"])
      |> List.wrap()
      |> Enum.reduce({:noop, []}, &merge/2)
    after
      Mix.shell(shell)
    end
  end

  defp merge(:noop, acc), do: acc

  defp merge({status, diags}, {acc_status, acc_diags}) do
    status =
      cond do
        :error in [status, acc_status] -> :error
        :ok in [status, acc_status] -> :ok
        true -> :noop
      end

    {status, acc_diags ++ diags}
  end

  # Mix deleted stale modules (and their beams) before failing: load the cached
  # code of everything that was loaded or whose beam is gone.
  defp restore(cache, loaded_before, disk) do
    for {m, {p, _, _}} <- disk,
        bin = cache[m],
        bin != nil and :code.is_loaded(m) == false,
        m in loaded_before or not File.exists?(p),
        {:error, e} <- [:code.load_binary(m, String.to_charlist(p), bin)],
        do: Logger.warning("reload restore of #{inspect(m)} failed: #{inspect(e)}")
  end

  # Beams on disk before Mix runs. A beam rolled back in memory stays on disk
  # with its bad code, so only beams Mix rewrote count, never "recent" ones.
  # A same-second same-size rewrite can keep the stat (ext4 reuses inodes), so
  # recently written beams are also kept by content.
  defp disk_state(dirs) do
    recent = System.os_time(:second) - 2

    for {m, p} <- beam_paths(dirs), {:ok, st} <- [File.stat(p, time: :posix)], into: %{} do
      {m, {p, {st.mtime, st.size, st.inode}, if(st.mtime >= recent, do: File.read!(p))}}
    end
  end

  defp rewritten?(nil, _p), do: true

  defp rewritten?({_, key, bytes}, p) do
    case File.stat(p, time: :posix) do
      {:ok, st} ->
        {st.mtime, st.size, st.inode} != key or (bytes != nil and File.read!(p) != bytes)

      _ ->
        true
    end
  end

  defp diff(cache, disk) do
    beams = beam_paths(current_ebin_dirs())

    changed =
      for {m, p} <- beams,
          rewritten?(disk[m], p),
          bin = File.read!(p),
          bin != cache[m],
          into: %{},
          do: {m, bin}

    removed = for {m, _} <- cache, !Map.has_key?(beams, m), do: m
    previous = Map.new(Map.keys(changed) ++ removed, &{&1, cache[&1]})
    # a removed module's beam was where Mix deleted it from
    removed_paths = for m <- removed, {p, _, _} <- [disk[m]], into: %{}, do: {m, p}
    paths = Map.merge(Map.take(beams, Map.keys(changed)), removed_paths)
    %{changed: changed, removed: removed, previous: previous, paths: paths}
  end

  defp update_mtime(p, acc) do
    case mtime(p) do
      {:ok, m} -> Map.put(acc, p, m)
      _ -> Map.delete(acc, p)
    end
  end

  defp mtime(path) do
    with {:ok, %{mtime: m}} <- File.stat(path, time: :posix), do: {:ok, m}
  end

  defp in_project(opts, fun) do
    case opts[:project_dir] do
      nil -> fun.()
      dir -> Mix.Project.in_project(opts[:app], dir, fn _ -> fun.() end)
    end
  end

  defp current_ebin_dirs do
    apps =
      case Mix.Project.apps_paths() do
        nil -> [Mix.Project.config()[:app]]
        paths -> Map.keys(paths)
      end

    build = Mix.Project.build_path()
    Map.new(apps, &{&1, Path.join([build, "lib", Atom.to_string(&1), "ebin"])})
  end

  defp beam_paths(dirs) do
    for dir <- Map.values(dirs), p <- Path.wildcard(Path.join(dir, "*.beam")), into: %{} do
      {String.to_atom(Path.basename(p, ".beam")), p}
    end
  end

  defp read_beams(dirs), do: Map.new(beam_paths(dirs), fn {m, p} -> {m, File.read!(p)} end)
end
