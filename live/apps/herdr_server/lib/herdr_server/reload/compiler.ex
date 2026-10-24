defmodule HerdrServer.Reload.Compiler do
  @moduledoc """
  Drives Mix's incremental compiler for one reload batch and reports what changed.

  Loading is left to the caller; Mix itself deletes the current code of every
  recompiled module, so new code autoloads from disk until the caller loads it.

  `changed` holds modules whose beam was rewritten with different bytes:
  byte-identical rewrites (a dependent recompiled to the same code) are not
  fan-out. `opts[:project_dir]` and `opts[:app]` run every Mix call inside that
  project instead of the current one.
  """

  alias HerdrServer.Reload.Loader
  alias Mix.Task.Compiler, as: MixCompiler

  @type cache :: %{module() => binary()}
  @type result :: %{
          changed: cache(),
          removed: [module()],
          previous: %{module() => binary() | nil},
          diagnostics: list(),
          mtimes: %{Path.t() => integer()}
        }

  @doc "Ebin dir per app of the project (umbrella children or the single app); deps excluded."
  @spec ebin_dirs(keyword()) :: %{atom() => Path.t()}
  def ebin_dirs(opts), do: in_project(opts, fn -> current_ebin_dirs() end)

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

    loaded_before = for {m, _} <- cache, :code.is_loaded(m), into: %{}, do: {m, :code.which(m)}
    t0 = System.os_time(:second)
    {status, diags} = mix_compile()
    mtimes = Enum.reduce(paths, mtimes, &update_mtime/2)

    case status do
      :error ->
        restore(cache, loaded_before)
        {:error, diags, mtimes}

      _ ->
        {:ok, diff(cache, t0) |> Map.merge(%{diagnostics: diags, mtimes: mtimes})}
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

  # Mix deleted stale modules before failing; put back what was loaded.
  defp restore(cache, loaded_before) do
    for {m, path} <- loaded_before, !:code.is_loaded(m) do
      :code.load_binary(m, path, cache[m])
    end
  end

  defp diff(cache, t0) do
    beams = beam_paths(current_ebin_dirs())

    changed =
      for {m, p} <- beams,
          {:ok, mt} <- [mtime(p)],
          mt >= t0 - 1,
          bin = File.read!(p),
          bin != cache[m],
          into: %{},
          do: {m, bin}

    removed = for {m, _} <- cache, !Map.has_key?(beams, m), do: m
    previous = Map.new(Map.keys(changed) ++ removed, &{&1, cache[&1]})
    %{changed: changed, removed: removed, previous: previous}
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
