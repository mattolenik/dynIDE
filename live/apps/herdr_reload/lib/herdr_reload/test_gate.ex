defmodule HerdrReload.TestGate do
  @moduledoc """
  Optional test-on-save gate (`:test_on_save` in the `HerdrReload` app env, `:off` by
  default, `:gate` with `HERDR_LIVE_TEST_ON_SAVE=1` or `herdr-live test-on-save on`).

  With `:gate`, a save first runs the changed module's ExUnit file (`apps/<app>/lib/x.ex`
  maps to `apps/<app>/test/x_test.exs` when it exists; a saved test file maps to itself)
  in a separate `mix test` OS process (`MIX_ENV=test`, the live VM's broker/control env
  removed), and only a pass reloads. It adds seconds of latency, which is why it is off
  by default. No mapped tests and nothing blocked: reload as usual (telemetry
  `tests result=none`).

  Batches are gated one at a time in this process (a named GenServer, `reload/1` is a
  call). `Server.reload` compiles every stale source, so a failed save must not be
  loaded by a later batch: the paths of a failed or errored gate are kept in a blocked
  set (the reload fun is not called, so the digest stays unrecorded). Every later batch
  in `:gate` mode also runs the blocked paths' tests, reloads only if all pass, and a
  pass clears the set. So fixing the code and saving any file retries the blocked
  tests. The Watcher watches `apps/*/lib` only: saving a test file alone triggers
  nothing; re-save a lib file. If any source under `apps/*/lib` changed (or appeared or
  vanished) while the tests ran, that reload is skipped (`tests result=stale` in telemetry) and the newer save's batch,
  queued behind, gates it. `set_mode(:off)` clears the blocked set: `:off` loads
  whatever is on disk at the next save. The runtime mode does not survive a VM handoff
  (the new VM reads the config / `HERDR_LIVE_TEST_ON_SAVE`).

  The gate holds only for loads in this VM. A blocked (failing-tests) source is still on
  disk: a new standby VM (`mix run`) compiles it, and a crash promotion's sync or the
  next ungated batch in a new VM loads it; the blocked set does not survive a handoff.
  Fix or revert a blocked source before `kernel-restart`.

  A crash of this process loses the blocked set (and restarts the Watcher, supervisor
  `rest_for_one`); a start in `:gate` mode logs a warning so a restart is visible.

  Notices: `{:tests, :running | :passed | :failed | :error | :none, %{files, failures,
  ms}}` (`:none`: a gated batch with no mapped tests and nothing blocked).
  """

  use GenServer

  require Logger

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
    if mode == :off and GenServer.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :clear)
    :ok
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

  # lib/<app>/x.ex is tested by test/x_test.exs (the repo's convention) or test/<app>/x_test.exs
  defp lib_test(root, app, rest) do
    [rest, if(hd(rest) == app, do: tl(rest), else: [])]
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&(&1 |> Path.join() |> String.replace_suffix(".ex", "_test.exs")))
    |> Enum.flat_map(&test_file(root, app, [&1]))
    |> Enum.take(1)
  end

  defp test_file(root, app, rest) do
    rel = Path.join(["test" | rest])
    dir = Path.join([root, "apps", app])

    if String.ends_with?(rel, "_test.exs") and File.regular?(Path.join(dir, rel)),
      do: [{dir, rel}],
      else: []
  end

  @doc "Starts the gate process (`name:` option for tests, default the module name)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  @doc "`reload/2` with the defaults (the Watcher's `on_batch`)."
  @spec reload([Path.t()]) :: term()
  def reload(paths), do: reload(paths, [])

  @doc """
  Reloads `paths`, behind the gate when the mode is `:gate`. Options (for tests):
  `reload` (fun, default `Server.reload/1`), `runner`, `root`, `mode`, `server` (the gate
  process, default the module name).
  """
  @spec reload([Path.t()], keyword()) :: term()
  def reload(paths, opts) do
    case Keyword.get_lazy(opts, :mode, &mode/0) do
      :off -> Keyword.get(opts, :reload, &Server.reload/1).(paths)
      :gate -> GenServer.call(Keyword.get(opts, :server, __MODULE__), {:reload, paths, opts}, :infinity)
    end
  end

  # blocked: paths whose gate failed or errored, not yet passed; root: the umbrella root,
  # taken once at init (during an umbrella compile Mix.Project.project_file/0 can point at
  # a child app)
  defstruct blocked: MapSet.new(), root: nil

  @impl true
  def init(nil) do
    # a crash loses the blocked set (and, under rest_for_one, restarts the Watcher)
    if mode() == :gate, do: Logger.warning("test gate (re)started: blocked set is empty")
    {:ok, %__MODULE__{root: root()}}
  end

  @impl true
  def handle_call({:reload, paths, opts}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = if state.root, do: state, else: %{state | root: root()}
    {reply, blocked} = gated(paths, state.blocked, Keyword.put_new(opts, :root, state.root))
    {:reply, reply, %{state | blocked: blocked}}
  end

  @impl true
  def handle_cast(:clear, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | blocked: MapSet.new()}}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  defp gated(paths, blocked, opts) do
    reload_fun = Keyword.get(opts, :reload, &Server.reload/1)
    root = Keyword.fetch!(opts, :root)
    all = Enum.uniq(paths ++ MapSet.to_list(blocked))
    tests = tests_for(all, root)

    if map_size(tests) == 0 do
      # clears a "tests..." a stale run left in the chrome; logs `tests result=none`
      Notices.broadcast({:tests, :none, %{files: 0, failures: 0, ms: 0}})
      {reload_fun.(paths), MapSet.new()}
    else
      snapshot = snapshot(root, all)
      n = tests |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      Notices.broadcast({:tests, :running, %{files: n}})
      {result, info} = run(tests, opts)
      after_run(result, info, {paths, all, blocked}, {root, snapshot}, reload_fun)
    end
  end

  # A pass reloads only if no source changed while the tests ran: Server.reload compiles
  # every stale source, so another file saved meanwhile would be loaded ungated. The
  # stale outcome broadcasts no result (chrome keeps "tests..." until the queued batch
  # for that save reports, `:none` if it has no mapped tests).
  defp after_run(:passed, info, {_paths, all, blocked}, {root, snapshot}, reload_fun) do
    if snapshot(root, all) == snapshot do
      Notices.broadcast({:tests, :passed, info})
      {reload_fun.(all), MapSet.new()}
    else
      Telemetry.event(:tests, result: :stale, files: info.files, failures: 0, ms: info.ms)
      {{:tests, :stale, info}, blocked}
    end
  end

  defp after_run(result, info, {paths, _all, blocked}, _ctx, _reload_fun) do
    Notices.broadcast({:tests, result, info})
    {{:tests, result, info}, MapSet.union(blocked, MapSet.new(paths))}
  end

  # content digests of every source the Server could compile, plus the given paths
  defp snapshot(root, extra) do
    sources = Path.wildcard(Path.join(root, "apps/*/lib/**/*.{ex,exs,erl,hrl,eex,heex}"))
    Map.new(sources ++ extra, &{&1, digest(&1)})
  end

  defp digest(path) do
    case File.read(path) do
      {:ok, bin} -> :erlang.md5(bin)
      _ -> nil
    end
  end

  defp root, do: Path.dirname(Mix.Project.project_file())

  @doc """
  Runs `mix test <files>` in each app dir (stops at the first app that does not pass).
  Options: `runner` `(app_dir, args, env, timeout_ms -> {output, status} | :timeout)`, `exe`
  (the executable the default runner starts, default `mix`), `timeout_ms`.
  """
  @spec run(%{Path.t() => [Path.t()]}, keyword()) ::
          {result(), %{files: integer(), failures: integer(), ms: integer()}}
  def run(tests, opts \\ []) do
    exe = Keyword.get(opts, :exe)
    runner = Keyword.get(opts, :runner, &port_runner(&1, &2, &3, &4, exe))
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
  defp port_runner(dir, args, env, timeout, exe) do
    case exe || System.find_executable("mix") do
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
        # exactly the pid we started, never by name. kill -9 of the BEAM itself can orphan
        # mix's children; acceptable for a 120 s safety net.
        System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
        # the port closes itself on the exit status
        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          2_000 -> :ok
        end

        :timeout
    end
  end
end
