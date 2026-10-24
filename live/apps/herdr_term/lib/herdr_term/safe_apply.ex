defmodule HerdrTerm.SafeApply do
  @moduledoc """
  The boundary between thin client processes and editable code: runs
  `apply(m, f, a)` and turns a raise, throw or exit into `{:failed, reason}`
  (logged). Same shape as M4's `Reload.Guard.run/4`; `opts` is reserved for
  its budget and rollback options.
  """

  require Logger

  @spec run(module, atom, list, keyword) :: {:ok, term} | {:failed, term}
  def run(m, f, a, _opts \\ []) do
    {:ok, apply(m, f, a)}
  catch
    kind, reason ->
      Logger.error(
        "safe_apply #{inspect(m)}.#{f}/#{length(a)} failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:failed, {kind, reason}}
  end
end
