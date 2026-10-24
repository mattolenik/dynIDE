defmodule HerdrReload.Guard do
  @moduledoc """
  Runs a call into reloadable code, turning any raise, throw, exit, timeout or
  local fun in the result into `{:failed, failure}` and blaming it on the
  newest live reload batch, which the Server rolls back.

  A worker process is used only when `budget_ms` is set; otherwise the call
  runs inline. Spawning copies the args to the worker heap, so large state on
  the keystroke path should run inline, with a budget only where a hang is
  plausible (View.compute).

  Success never calls the Server: it bumps the counters in the public ETS
  table named after the server (`mod` and `:total`).
  """

  alias HerdrReload.{LocalFuns, Notices, Server, Telemetry}

  require Logger

  @type stack :: [term()]
  @type failure ::
          {:raise, Exception.t(), stack()}
          | {:throw, term(), stack()}
          | {:exit, term(), stack()}
          | {:timeout, pos_integer(), stack()}
          | {:local_fun, module(), LocalFuns.path()}

  @doc """
  Applies `fun` of `mod` to `args`. Opts: `budget_ms` (nil runs inline),
  `server` (default `HerdrReload.Server`), `scan` (local fun scan of
  the result; defaults to the `:scan_local_funs` config), `attribute`
  (default true; false never calls `Server.fail`, so nothing rolls back).
  """
  @spec run(module(), atom(), [term()], keyword()) :: {:ok, term()} | {:failed, failure()}
  def run(mod, fun, args, opts \\ []) do
    mod |> attributed_run(fun, args, opts) |> plain()
  end

  defp attributed_run(mod, fun, args, opts) do
    server = Keyword.get(opts, :server, Server)

    case call(mod, fun, args, opts[:budget_ms]) do
      {:ok, value} -> succeeded(mod, value, server, opts)
      failure -> failed(stack_modules(mod, failure), failure, server, opts)
    end
  end

  @doc """
  The call-site shape: `run/4` with every failure logged. A failure that
  rolled a batch back is re-run once on the old code; an unattributed one
  would only fail again, so it is returned at once. The re-run never
  attributes: the old code failing too means corrupt state, not another bad
  batch.
  """
  @spec run_twice(module(), atom(), [term()], keyword()) :: {:ok, term()} | {:failed, failure()}
  def run_twice(mod, fun, args, opts \\ []) do
    case run_twice_attributed(mod, fun, args, opts) do
      {:failed, failure, _} -> {:failed, failure}
      ok -> ok
    end
  end

  @doc """
  `run_twice/4`, but a failure also says which batch the first run rolled back:
  a batch id means the old code failed on the same call too (a repeat failure),
  `nil` that the failure was unattributed.
  """
  @spec run_twice_attributed(module(), atom(), [term()], keyword()) ::
          {:ok, term()} | {:failed, failure(), pos_integer() | nil}
  def run_twice_attributed(mod, fun, args, opts \\ []) do
    case logged_run(mod, fun, args, opts) do
      {:failed, _, {:rolled_back, id}} ->
        case logged_run(mod, fun, args, Keyword.put(opts, :attribute, false)) do
          {:failed, failure, _} -> {:failed, failure, id}
          ok -> ok
        end

      {:failed, failure, _} ->
        {:failed, failure, nil}

      ok ->
        ok
    end
  end

  defp plain({:failed, failure, _attribution}), do: {:failed, failure}
  defp plain(ok), do: ok

  defp logged_run(mod, fun, args, opts) do
    with {:failed, failure, attribution} = failed <- attributed_run(mod, fun, args, opts) do
      log(mod, fun, args, failure)
      telemetry(mod, fun, args, failure, attribution)
      failed
    end
  end

  defp log(mod, fun, args, failure) do
    stack =
      case failure do
        {:local_fun, _, _} -> ""
        {_, _, s} -> Exception.format_stacktrace(s)
      end

    Logger.error("#{inspect(mod)}.#{fun}/#{length(args)} failed: #{message(failure)}\n#{stack}")
  end

  defp telemetry(mod, fun, args, failure, attribution) do
    attributed =
      case attribution do
        {:rolled_back, id} -> id
        _ -> :none
      end

    Telemetry.event(:guard_failure,
      mfa: "#{inspect(mod)}.#{fun}/#{length(args)}",
      kind: elem(failure, 0),
      attributed: attributed,
      detail: message(failure)
    )
  end

  @doc "One-line description of a failure, without its stack."
  @spec message(failure()) :: String.t()
  def message({:raise, e, _}), do: Exception.format_banner(:error, e)
  def message({:throw, v, _}), do: Exception.format_banner(:throw, v)
  def message({:exit, r, _}), do: Exception.format_banner(:exit, r)
  def message({:timeout, ms, _}), do: "timed out after #{ms}ms"
  def message({:local_fun, m, path}), do: "result holds a local fun of #{inspect(m)} at #{inspect(path)}"

  defp scan?(opts) do
    Keyword.get_lazy(opts, :scan, fn ->
      Application.get_env(:herdr_reload, HerdrReload, [])[:scan_local_funs]
    end)
  end

  defp call(mod, fun, args, nil), do: attempt(mod, fun, args)

  # No link in either direction: a trapping caller gets no EXIT messages and an
  # external kill of the worker cannot take the caller down. A watcher ties the
  # worker's life to the caller instead.
  defp call(mod, fun, args, budget_ms) do
    tag = make_ref()
    parent = self()

    {pid, mref} =
      spawn_monitor(fn ->
        watch(parent, self())
        send(parent, {tag, attempt(mod, fun, args)})
      end)

    receive do
      {^tag, outcome} ->
        Process.demonitor(mref, [:flush])
        outcome

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:exit, reason, []}
    after
      budget_ms ->
        stack =
          case Process.info(pid, :current_stacktrace) do
            {:current_stacktrace, s} -> s
            nil -> []
          end

        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mref, :process, ^pid, _} -> :ok
        end

        # a reply may have raced the deadline
        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        {:timeout, budget_ms, stack}
    end
  end

  # Kills `worker` if `caller` dies first; exits once the worker is gone.
  defp watch(caller, worker) do
    spawn(fn ->
      cref = Process.monitor(caller)
      wref = Process.monitor(worker)

      receive do
        {:DOWN, ^cref, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^wref, :process, _, _} -> :ok
      end
    end)
  end

  # The only blanket rescue/catch allowed in the codebase: everything a
  # reloaded module can throw at its caller becomes a failure value.
  defp attempt(mod, fun, args) do
    {:ok, apply(mod, fun, args)}
  rescue
    e -> {:raise, e, __STACKTRACE__}
  catch
    :throw, value -> {:throw, value, __STACKTRACE__}
    :exit, reason -> {:exit, reason, __STACKTRACE__}
  end

  defp succeeded(mod, value, server, opts) do
    if is_atom(server) and :ets.whereis(server) != :undefined do
      :ets.update_counter(server, mod, 1, {mod, 0})
      :ets.update_counter(server, :total, 1, {:total, 0})
    end

    case scan?(opts) && LocalFuns.find(value) do
      {:local_fun, fun_mod, path} = failure ->
        # the re-run after a rollback repeats the first run's notice: say it once
        if Keyword.get(opts, :attribute, true), do: Notices.broadcast({:rejected, fun_mod, path})
        failed(Enum.uniq([fun_mod, mod]), failure, server, opts)

      _ ->
        {:ok, value}
    end
  end

  # stamped now: the Server may be mid-compile and only answers once it has loaded
  defp failed(stack_modules, failure, server, opts) do
    at = System.monotonic_time(:millisecond)

    if Keyword.get(opts, :attribute, true),
      do: {:failed, failure, attribute(server, stack_modules, failure, at)},
      else: {:failed, failure, :unattributed}
  end

  # A server dying between whereis and the call must not crash the caller.
  defp attribute(server, stack_modules, failure, at) do
    if GenServer.whereis(server),
      do: Server.fail(server, stack_modules, failure, at),
      else: :unattributed
  catch
    :exit, _ -> :unattributed
  end

  @doc false
  @spec stack_modules(module(), failure()) :: [module()]
  def stack_modules(mod, {:exit, reason, stack}) when is_list(stack),
    do: Enum.uniq([mod | frame_modules(stack) ++ frame_modules(nested_stack(reason))])

  def stack_modules(mod, {_, _, stack}) when is_list(stack),
    do: Enum.uniq([mod | frame_modules(stack)])

  def stack_modules(mod, _), do: [mod]

  defp nested_stack({{_, stack}, {GenServer, :call, _}}) when is_list(stack), do: stack
  defp nested_stack({_, stack}) when is_list(stack), do: stack
  defp nested_stack(_), do: []

  # Frames from the first Guard frame on belong to the caller, not the guarded
  # call, so they must not steer attribution.
  defp frame_modules(frames) do
    for {m, f, a, loc} <- Enum.take_while(frames, &(not match?({__MODULE__, _, _, _}, &1))),
        is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)) and is_list(loc),
        do: m
  end
end
