defmodule HerdrServer.Pane.Facts do
  @moduledoc """
  Per-pane terminal facts in `:herdr_pane_facts` (owned by `HerdrServer.Mirror`), so
  any process reads them without a call and a restarted `Pane.Server` gets them back.

  Keys: a pane id -> `t:facts/0`, written only by that pane's `Pane.Server`;
  `:host_colors` -> the foreground client's colour caps (`%{colors, scheme}`, either
  key optional), applied by every `Pane.Server` on init; `:foreground` -> the
  foreground client session pid (`Client.Foreground`).

  `scroll` is the vt's scrollbar (`total`, `viewport`, `offset` = top row of the
  viewport); `scrolled` is true while the viewport is above the bottom. `scroll` is
  kept current only while scrolled (an unscrolled pane's growing scrollback is not
  rewritten on every damage). Plain ETS API, no process.

  Pane rows are `{id, facts, pending}`: `pending` is the count of writes queued in the
  pane's `Pane.Server` (`add_pending/2`); other rows are `{key, value}`. Keeping it in the facts row lets
  the input fast path read both facts with one lookup (`input/1`), and a counter (bumped
  by the writer before its cast, dropped by the server after the write) cannot race
  the way a set/clear flag would.

  A VM that hot-loads this module before `Mirror` has created the table reads nil and
  skips writes; the first skipped write wakes `Mirror`, which creates it.
  """

  @table :herdr_pane_facts

  @type facts :: %{
          scroll: %{total: non_neg_integer, viewport: non_neg_integer, offset: non_neg_integer},
          scrolled: boolean,
          alt_screen: boolean,
          cwd: binary | nil,
          title: binary | nil,
          stripped_title: binary | nil,
          progress: binary | nil
        }

  @spec get(pos_integer | atom) :: term | nil
  def get(key) do
    case lookup(key) do
      [row] -> elem(row, 1)
      [] -> nil
    end
  end

  @spec put(pos_integer | atom, term) :: :ok
  def put(key, value) do
    if :ets.whereis(@table) == :undefined, do: wake_owner(), else: put_value(key, value)
    :ok
  end

  # a pane row keeps its pending count (a `{id, facts}` row from before the write queue
  # existed, kept over a hot reload, becomes `{id, facts, 0}`)
  defp put_value(key, value) when not is_integer(key), do: :ets.insert(@table, {key, value})

  defp put_value(key, value) do
    with false <- :ets.insert_new(@table, {key, value, 0}) do
      case :ets.lookup(@table, key) do
        [{_, _, _}] -> :ets.update_element(@table, key, {2, value})
        _ -> :ets.insert(@table, {key, value, 0})
      end
    end
  end

  @spec delete(pos_integer) :: :ok
  def delete(id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, id)
    :ok
  end

  @doc "Whether pane `id` is scrolled back (one ETS lookup; the input fast path uses it)."
  @spec scrolled?(pos_integer) :: boolean
  def scrolled?(id), do: elem(input(id), 0)

  @doc "Whether pane `id` has writes queued in its `Pane.Server`."
  @spec pending?(pos_integer) :: boolean
  def pending?(id), do: elem(input(id), 1)

  @doc """
  `{scrolled?, pending?, alt_screen?}` for pane `id` with one ETS lookup (the input fast
  path). `alt_screen?` is the fact as of the pane's last damage.
  """
  @spec input(pos_integer) :: {boolean, boolean, boolean}
  def input(id) do
    case lookup(id) do
      [{_, facts, n}] -> {back?(facts), n > 0, alt?(facts)}
      [{_, facts}] -> {back?(facts), false, alt?(facts)}
      [] -> {false, false, false}
    end
  end

  defp back?(facts), do: match?(%{scrolled: true}, facts)
  defp alt?(facts), do: match?(%{alt_screen: true}, facts)

  @doc """
  Adds `n` (negative to drop) to pane `id`'s pending write count, never below 0. A
  missing table is a no-op (writes then go direct, as before the queue existed).
  """
  @spec add_pending(pos_integer, integer) :: :ok
  def add_pending(id, n) do
    op = if n < 0, do: {3, n, 0, 0}, else: {3, n}
    :ets.update_counter(@table, id, op, {id, nil, 0})
    :ok
  rescue
    # no table, or a `{id, facts}` row from before the queue: give it the count
    ArgumentError ->
      with [{^id, facts}] <- lookup(id), do: :ets.insert(@table, {id, facts, max(n, 0)})
      :ok
  end

  @doc "Resets pane `id`'s pending count (a starting `Pane.Server` has an empty queue)."
  @spec reset_pending(pos_integer) :: :ok
  def reset_pending(id) do
    :ets.update_element(@table, id, {3, 0})
    :ok
  rescue
    # no table, or a `{id, facts}` row from before the queue
    ArgumentError ->
      with [{^id, facts}] <- lookup(id), do: :ets.insert(@table, {id, facts, 0})
      :ok
  end

  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    # no table yet (see moduledoc)
    ArgumentError -> []
  end

  defp wake_owner do
    case Process.whereis(HerdrServer.Mirror) do
      nil -> :ok
      pid -> send(pid, :ensure_tables)
    end
  end

  @spec host_colors() :: map | nil
  def host_colors, do: get(:host_colors)

  @doc """
  Merges `caps`' `:colors` and `:scheme` (whichever are present) into the host colours.
  `colors` is `Kernel.Vt.colors()` (`fg`/`bg`/`cursor` rgb or nil, `palette` index 0..255
  -> rgb), `scheme` `:dark | :light | nil`; anything else is rejected and nothing stored.
  """
  @spec put_host_colors(map) :: :ok | {:error, :invalid}
  def put_host_colors(caps) do
    new = Map.take(caps, [:colors, :scheme])

    if valid_colors?(Map.get(new, :colors, %{})) and Map.get(new, :scheme) in [:dark, :light, nil],
      do: put(:host_colors, Map.merge(host_colors() || %{}, new)),
      else: {:error, :invalid}
  end

  defp valid_colors?(c) when is_map(c) do
    Enum.all?(c, fn
      {k, v} when k in [:fg, :bg, :cursor] -> v == nil or rgb?(v)
      {:palette, p} when is_map(p) -> Enum.all?(p, fn {i, v} -> i in 0..255 and rgb?(v) end)
      _ -> false
    end)
  end

  defp valid_colors?(_), do: false

  defp rgb?({r, g, b}), do: Enum.all?([r, g, b], &(&1 in 0..255))
  defp rgb?(_), do: false
end
