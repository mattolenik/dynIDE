defmodule DynideServer.RuntimeStatus do
  @moduledoc """
  Pure runtime status for the status line: the last reload event (batch and fan-out,
  compile error, rollback with reason, promotion sync, rejection, purge block), the
  last test-on-save result and the last handoff phase.

  `apply/3` folds `{:dynide_reload, event}` and `{:handoff, map}` events into it (the
  newer event replaces the older one in its slot); `expire/2` drops a handoff entry
  30 s old (reload and tests never expire); `nodes/2` gives the `:status` children, in
  priority order reload > tests > handoff, dropping from the lowest until they fit.
  A handoff map may carry `:kind` (`:graceful | :crash | nil`, the caller reads
  `Handoff.Link.adopt_reason/0`); `at` is the caller's monotonic ms. A node's props
  are only its counts (`batch`/`fanout`, `files`/`failures`, `gen`/`panes`), never the
  state atoms or module names a remote client cannot decode.
  """
  import Kernel, except: [apply: 2, apply: 3]

  alias DynideReload.Guard
  alias DynideScene.Scene.Node

  @handoff_ms 30_000
  @reason_cols 24
  @reason_max 80

  @type reload :: %{
          state: :loaded | :compile_error | :rolled_back | :synced | :rejected | :purge_blocked,
          batch: pos_integer | nil,
          fanout: non_neg_integer,
          modules: [module],
          reason: String.t() | nil,
          at: integer
        }
  @type tests :: %{
          result: :running | :passed | :failed | :error,
          files: non_neg_integer,
          failures: non_neg_integer,
          ms: non_neg_integer | nil
        }
  @type handoff :: %{
          phase: :begin | :aborted | :released | :adopted,
          kind: :crash | :graceful | nil,
          gen: integer,
          panes: non_neg_integer,
          at: integer
        }
  @type t :: %{reload: reload | nil, tests: tests | nil, handoff: handoff | nil}

  @spec new() :: t
  def new, do: %{reload: nil, tests: nil, handoff: nil}

  @spec apply(t, term, integer) :: t
  def apply(t, event, now \\ System.monotonic_time(:millisecond))

  # a gated batch with no mapped tests: nothing to show
  def apply(t, {:dynide_reload, {:tests, :none, _info}}, _now), do: %{t | tests: nil}

  def apply(t, {:dynide_reload, {:tests, result, info}}, _now)
      when result in [:running, :passed, :failed, :error] and is_map(info) do
    tests = %{
      result: result,
      files: Map.get(info, :files, 0),
      failures: Map.get(info, :failures, 0),
      ms: Map.get(info, :ms)
    }

    %{t | tests: tests}
  end

  def apply(t, {:dynide_reload, {:synced, []}}, _now), do: t

  def apply(t, {:dynide_reload, ev}, now) do
    case reload(ev) do
      nil -> t
      r -> %{t | reload: Map.put(r, :at, now)}
    end
  end

  def apply(t, {:handoff, %{phase: phase, gen: gen, panes: panes} = m}, now) do
    %{
      t
      | handoff: %{phase: phase, kind: Map.get(m, :kind), gen: gen, panes: length(panes), at: now}
    }
  end

  def apply(t, _event, _now), do: t

  @spec expire(t, integer) :: t
  def expire(%{handoff: %{at: at}} = t, now) when now - at >= @handoff_ms, do: %{t | handoff: nil}
  def expire(t, _now), do: t

  @doc "The status children for `t`, at most `free_cols` cells (text plus one gap each)."
  @spec nodes(t | nil, integer) :: [Node.t()]
  def nodes(nil, _free), do: []

  def nodes(t, free) do
    [reload_node(t.reload), tests_node(t.tests), handoff_node(t.handoff)]
    |> Enum.reject(&is_nil/1)
    |> fit(free, [])
  end

  @doc "One-line summary of a rollback reason (`:manual`, a Guard failure, `{reason, load_errors}`)."
  @spec reason(term) :: String.t()
  def reason(:manual), do: "manual"
  def reason(text) when is_binary(text), do: text
  def reason({reason, errs}) when is_list(errs), do: reason(reason) <> " (load errors)"

  def reason({k, _, _} = reason) when k in [:raise, :throw, :exit, :timeout, :local_fun],
    do: Guard.message(reason)

  def reason(reason), do: inspect(reason)

  # --- reload ---

  defp reload({:loaded, id, mods}), do: r(:loaded, id, mods, nil)

  defp reload({:rolled_back, id, mods, why}),
    do: r(:rolled_back, id, mods, why |> reason() |> one_line())

  defp reload({:compile_error, diags}),
    do: r(:compile_error, nil, [], diags |> diag() |> one_line())

  defp reload({:synced, mods}), do: r(:synced, nil, mods, nil)
  defp reload({:rejected, mod, _path}), do: r(:rejected, nil, [mod], nil)
  defp reload({:purge_blocked, mod, _holders}), do: r(:purge_blocked, nil, [mod], nil)
  defp reload(_), do: nil

  defp r(state, batch, mods, reason),
    do: %{state: state, batch: batch, fanout: length(mods), modules: mods, reason: reason}

  defp diag([%{message: m} | _]), do: IO.chardata_to_string(m)
  defp diag(_), do: "compile error"

  defp one_line(s), do: s |> String.replace(~r/\s+/, " ") |> String.slice(0, @reason_max)

  # --- nodes ---

  defp reload_node(nil), do: nil

  defp reload_node(r) do
    {text, token} =
      case r.state do
        :loaded ->
          {"r#{r.batch} #{r.fanout}m", :muted}

        :compile_error ->
          {"r! compile", :error}

        :rolled_back ->
          {"r#{r.batch} rolled back: #{String.slice(r.reason, 0, @reason_cols)}", :warning}

        :synced ->
          {"synced #{r.fanout}m, no rollback", :warning}

        :rejected ->
          {"r rejected", :warning}

        :purge_blocked ->
          {"r blocked", :warning}
      end

    node(:reload, text, token, Map.take(r, [:batch, :fanout]))
  end

  defp tests_node(nil), do: nil

  defp tests_node(t) do
    {text, token} =
      case t.result do
        :running -> {"tests...", :muted}
        :passed -> {"tests ok", :muted}
        :failed -> {"tests #{t.failures} failed", :error}
        :error -> {"tests error", :error}
      end

    node(:tests, text, token, Map.take(t, [:files, :failures]))
  end

  defp handoff_node(nil), do: nil

  defp handoff_node(h) do
    text =
      case h do
        %{phase: :adopted, kind: nil} -> "handoff g#{h.gen}"
        %{phase: :adopted, kind: kind} -> "handoff #{kind} g#{h.gen}"
        %{phase: :aborted} -> "handoff aborted"
        _ -> "handoff..."
      end

    node(:handoff, text, :accent, Map.take(h, [:gen, :panes]))
  end

  # props stay small integers (or nil): a remote client decodes the scene with
  # `[:safe]` and knows no server atoms (states, kinds, module names, R7)
  defp node(id, text, token, props),
    do: %Node{role: :text, id: id, text: text, token: token, props: props}

  # the longest prefix (by priority) whose cells fit
  defp fit([], _free, acc), do: Enum.reverse(acc)

  defp fit([n | rest], free, acc) do
    w = String.length(n.text) + 1
    if w <= free, do: fit(rest, free - w, [n | acc]), else: Enum.reverse(acc)
  end
end
