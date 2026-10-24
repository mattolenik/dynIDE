defmodule HerdrReload.TestGate do
  @moduledoc """
  Optional test-on-save gate (`:test_on_save` in the `HerdrReload` app env, `:off` by
  default, `:gate` with `HERDR_LIVE_TEST_ON_SAVE=1` or `herdr-live test-on-save on`).

  With `:gate`, a save first runs the changed module's ExUnit file (`apps/<app>/lib/x.ex`
  maps to `apps/<app>/test/x_test.exs` when it exists; a saved test file maps to itself)
  in a separate `mix test` OS process (`MIX_ENV=test`, the live VM's broker/control env
  removed), and only a pass reloads. A failed or errored gate never calls the reload, so
  its digest is not recorded and the next save of the same bytes retries. No mapped
  tests: reload as usual (telemetry `tests result=none` only). It adds seconds of
  latency, which is why it is off by default.

  Notices: `{:tests, :running | :passed | :failed | :error, %{files, failures, ms}}`.
  """

  alias HerdrReload.{Notices, Server, Telemetry}

  @timeout_ms 120_000

  @unset ~w(HERDR_BROKER_SOCK HERDR_LIVE_GEN HERDR_LIVE_CONTROL HERDR_LIVE_LOG
            HERDR_LIVE_RUNTIME_DIR HERDR_LIVE_HEADLESS)

  @type result :: :passed | :failed | :error

  @doc "The gate mode."
  @spec mode() :: :off | :gate
  def mode do
    case Application.get_env(:herdr_reload, HerdrReload, []) |> Keyword.get(:test_on_save) do
      :gate -> :gate
      _ -> :off
    end
  end

  @doc "Sets the gate mode in the app env."
  @spec set_mode(:off | :gate) :: :ok
  def set_mode(mode) when mode in [:off, :gate] do
    env = Application.get_env(:herdr_reload, HerdrReload, [])
    Application.put_env(:herdr_reload, HerdrReload, Keyword.put(env, :test_on_save, mode))
  end

  @doc """
  Maps changed paths to test files, `%{app_dir => [test path relative to app_dir]}`
  (`app_dir` is `<umbrella_root>/apps/<app>`). Pure apart from the existence check.
  """
  @spec tests_for([Path.t()], Path.t()) :: %{Path.t() => [Path.t()]}
  def tests_for(paths, root) do
    paths
    |> Enum.flat_map(&test_for(&1, root))
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp test_for(path, root) do
    case path |> Path.relative_to(root) |> Path.split() do
      ["apps", app, "lib" | rest] when rest != [] -> lib_test(root, app, rest)
      ["apps", app, "test" | rest] when rest != [] -> test_file(root, app, rest)
      _ -> []
    end
  end

  defp lib_test(root, app, rest) do
    base = Path.join(rest)

    if String.ends_with?(base, ".ex"),
      do: test_file(root, app, [String.replace_suffix(base, ".ex", "_test.exs")]),
      else: []
  end

  defp test_file(root, app, rest) do
    rel = Path.join(["test" | rest])
    dir = Path.join([root, "apps", app])

    if String.ends_with?(rel, "_test.exs") and File.regular?(Path.join(dir, rel)),
      do: [{dir, rel}],
      else: []
  end

  @doc "`reload/2` with the default reload, runner and umbrella root (the Watcher's `on_batch`)."
  @spec reload([Path.t()]) :: term()
  def reload(paths), do: reload(paths, [])

  @doc """
  Reloads `paths`, behind the gate when the mode is `:gate`. Options (for tests):
  `reload` (fun, default `Server.reload/1`), `runner`, `root`, `mode`.
  """
  @spec reload([Path.t()], keyword()) :: term()
  def reload(paths, opts) do
    reload_fun = Keyword.get(opts, :reload, &Server.reload/1)

    case Keyword.get_lazy(opts, :mode, &mode/0) do
      :off -> reload_fun.(paths)
      :gate -> gated(paths, reload_fun, opts)
    end
  end

  defp gated(paths, reload_fun, opts) do
    root = Keyword.get_lazy(opts, :root, &root/0)

    case tests_for(paths, root) do
      tests when map_size(tests) == 0 ->
        Telemetry.event(:tests, result: :none, files: 0)
        reload_fun.(paths)

      tests ->
        n = tests |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
        Notices.broadcast({:tests, :running, %{files: n}})
        {result, info} = run(tests, opts)
        Notices.broadcast({:tests, result, info})
        if result == :passed, do: reload_fun.(paths), else: {:tests, result, info}
    end
  end

  defp root, do: Path.dirname(Mix.Project.project_file())

  @doc """
  Runs `mix test <files>` in each app dir (stops at the first app that does not pass).
  Option `runner`: `(app_dir, args, env, timeout_ms -> {output, status} | :timeout)`.
  """
  @spec run(%{Path.t() => [Path.t()]}, keyword()) ::
          {result(), %{files: integer(), failures: integer(), ms: integer()}}
  def run(tests, opts \\ []) do
    runner = Keyword.get(opts, :runner, &port_runner/4)
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)
    started = System.monotonic_time(:millisecond)
    files = tests |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    {result, failures} =
      Enum.reduce_while(tests, {:passed, 0}, fn {dir, rel}, {_, f} ->
        {res, n} = one(runner.(dir, ["test" | rel], env(), timeout))
        if res == :passed, do: {:cont, {:passed, f + n}}, else: {:halt, {res, f + n}}
      end)

    ms = System.monotonic_time(:millisecond) - started
    {result, %{files: files, failures: failures, ms: ms}}
  end

  @doc false
  def env, do: [{"MIX_ENV", "test"} | Enum.map(@unset, &{&1, nil})]

  defp one(:timeout), do: {:error, 0}

  defp one({out, status}) do
    failures =
      case Regex.run(~r/\d+ tests?, (\d+) failures?/, out) do
        [_, n] -> String.to_integer(n)
        nil -> nil
      end

    cond do
      status == 0 -> {:passed, failures || 0}
      failures && failures > 0 -> {:failed, failures}
      true -> {:error, 0}
    end
  end

  # System.cmd has no timeout: a port, so the OS pid can be killed when it runs over
  defp port_runner(dir, args, env, timeout) do
    case System.find_executable("mix") do
      nil ->
        {"mix not found", 127}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            cd: dir,
            env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)} end)
          ])

        {:os_pid, pid} = Port.info(port, :os_pid)
        collect(port, pid, [], System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp collect(port, pid, acc, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, d}} ->
        collect(port, pid, [acc | d], deadline)

      {^port, {:exit_status, s}} ->
        {IO.iodata_to_binary(acc), s}
    after
      left ->
        # exactly the pid we started, never by name
        System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
        Port.close(port)
        :timeout
    end
  end
end
