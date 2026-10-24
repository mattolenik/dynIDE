defmodule HerdrServer.SafeApply do
  @moduledoc """
  The boundary between thin GenServers and editable pure code: `run(m, f, a, opts)`
  applies `m.f(a...)` and turns a raise, throw or exit into `{:failed, reason}` (logged).
  This is the only blanket catch in herdr_server. `opts` keeps M4's
  `Reload.Guard.run/4` shape (e.g. `budget_ms`) and is ignored here.
  """

  require Logger

  @spec run(module, atom, list, keyword) :: {:ok, term} | {:failed, term}
  def run(m, f, a, _opts \\ []) do
    {:ok, apply(m, f, a)}
  rescue
    e -> failed(m, f, :error, e, __STACKTRACE__)
  catch
    :throw, v -> failed(m, f, :throw, v, __STACKTRACE__)
    :exit, r -> failed(m, f, :exit, r, __STACKTRACE__)
  end

  defp failed(m, f, kind, reason, stack) do
    Logger.error("#{inspect(m)}.#{f} failed: " <> Exception.format(kind, reason, stack))
    {:failed, if(kind == :error, do: reason, else: {kind, reason})}
  end
end
