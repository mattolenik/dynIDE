defmodule HerdrServer.Reload.Guard do
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

  alias HerdrServer.Reload.{LocalFuns, Notices, Server}

  @type stack :: [term()]
  @type failure ::
          {:raise, Exception.t(), stack()}
          | {:throw, term(), stack()}
          | {:exit, term(), stack()}
          | {:timeout, pos_integer(), stack()}
          | {:local_fun, module(), LocalFuns.path()}

  @doc """
  Applies `fun` of `mod` to `args`. Opts: `budget_ms` (nil runs inline),
  `server` (default `HerdrServer.Reload.Server`), `scan` (local fun scan of
  the result; defaults to the `:scan_local_funs` config).
  """
  @spec run(module(), atom(), [term()], keyword()) :: {:ok, term()} | {:failed, failure()}
  def run(mod, fun, args, opts \\ []) do
    server = Keyword.get(opts, :server, Server)

    case call(mod, fun, args, opts[:budget_ms]) do
      {:ok, value} -> succeeded(mod, value, server, scan?(opts))
      failure -> failed(stack_modules(mod, failure), failure, server)
    end
  end

  defp scan?(opts) do
    Keyword.get_lazy(opts, :scan, fn ->
      Application.get_env(:herdr_server, HerdrServer.Reload, [])[:scan_local_funs]
    end)
  end

  defp call(mod, fun, args, nil), do: attempt(mod, fun, args)

  defp call(mod, fun, args, budget_ms) do
    tag = make_ref()
    parent = self()

    {pid, mref} =
      Process.spawn(fn -> send(parent, {tag, attempt(mod, fun, args)}) end, [:link, :monitor])

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

        Process.unlink(pid)
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

  defp succeeded(mod, value, server, scan?) do
    if :ets.whereis(server) != :undefined do
      :ets.update_counter(server, mod, 1, {mod, 0})
      :ets.update_counter(server, :total, 1, {:total, 0})
    end

    case scan? && LocalFuns.find(value) do
      {:local_fun, fun_mod, path} = failure ->
        Notices.broadcast({:rejected, fun_mod, path})
        failed(Enum.uniq([fun_mod, mod]), failure, server)

      _ ->
        {:ok, value}
    end
  end

  defp failed(stack_modules, failure, server) do
    if GenServer.whereis(server), do: Server.fail(server, stack_modules, failure)
    {:failed, failure}
  end

  @doc false
  @spec stack_modules(module(), failure()) :: [module()]
  def stack_modules(mod, {:exit, {_, nested}, stack}) when is_list(nested),
    do: Enum.uniq([mod | frame_modules(stack ++ nested)])

  def stack_modules(mod, {_, _, stack}) when is_list(stack),
    do: Enum.uniq([mod | frame_modules(stack)])

  def stack_modules(mod, _), do: [mod]

  defp frame_modules(frames) do
    for {m, f, a, loc} <- frames,
        is_atom(m) and is_atom(f) and (is_integer(a) or is_list(a)) and is_list(loc),
        do: m
  end
end
