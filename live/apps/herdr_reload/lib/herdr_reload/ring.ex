defmodule HerdrReload.Ring do
  @moduledoc """
  Bounded history of reload batches (newest first) and the pure rules for
  deciding which batch is still "live" (recently exercised) and what to roll back.
  """

  alias HerdrReload.Batch

  defstruct depth: 1, batches: []

  @type t :: %__MODULE__{depth: pos_integer(), batches: [Batch.t()]}

  @doc "Creates an empty ring holding at most `depth` batches."
  @spec new(pos_integer()) :: t()
  def new(depth), do: %__MODULE__{depth: depth}

  @doc "Pushes a batch; returns the ring and any batches evicted beyond depth."
  @spec push(t(), Batch.t()) :: {t(), [Batch.t()]}
  def push(%__MODULE__{depth: depth, batches: batches} = ring, batch) do
    {kept, evicted} = Enum.split([batch | batches], depth)
    {%{ring | batches: kept}, evicted}
  end

  @doc "Batches, newest first."
  @spec batches(t()) :: [Batch.t()]
  def batches(%__MODULE__{batches: b}), do: b

  @doc "Fetches a batch by id."
  @spec get(t(), pos_integer()) :: Batch.t() | nil
  def get(%__MODULE__{batches: b}, id), do: Enum.find(b, &(&1.id == id))

  @doc "Applies `fun` to the batch with `id`."
  @spec update(t(), pos_integer(), (Batch.t() -> Batch.t())) :: t()
  def update(%__MODULE__{batches: b} = ring, id, fun) do
    %{ring | batches: Enum.map(b, fn x -> if x.id == id, do: fun.(x), else: x end)}
  end

  @doc """
  True while the batch may still be blamed for failures: not rolled back and
  inside the floor window or not yet exercised `exercise_n` times.
  """
  @spec live?(
          Batch.t(),
          %{module() => non_neg_integer()},
          non_neg_integer(),
          integer(),
          keyword()
        ) ::
          boolean()
  def live?(%Batch{rolled_back: true}, _counters, _total, _now, _opts), do: false

  def live?(%Batch{} = b, counters, total, now, opts) do
    n = Keyword.get(opts, :exercise_n, 20)
    floor_ms = Keyword.get(opts, :exercise_floor_ms, 5_000)

    now - b.loaded_at < floor_ms or total - b.total_baseline < n or
      Enum.any?(b.modules, fn m ->
        case counters do
          %{^m => count} -> count - Map.get(b.baseline, m, 0) < n
          _ -> false
        end
      end)
  end

  @doc "Newest live batch whose modules intersect `stack_modules`."
  @spec attribute(t(), [module()], (Batch.t() -> boolean())) :: Batch.t() | nil
  def attribute(%__MODULE__{batches: b}, stack_modules, live_fun) do
    Enum.find(b, fn x -> live_fun.(x) and Enum.any?(x.modules, &(&1 in stack_modules)) end)
  end

  @doc "Batch `id` plus newer non-rolled-back batches transitively sharing modules; newest first."
  @spec rollback_set(t(), pos_integer()) :: [Batch.t()]
  def rollback_set(%__MODULE__{batches: b}, id) do
    case Enum.find(b, &(&1.id == id)) do
      nil ->
        []

      target ->
        # batches are newest first; walk oldest to newest from the target
        b
        |> Enum.filter(&(&1.id > id and not &1.rolled_back))
        |> Enum.reverse()
        |> Enum.reduce({[target], MapSet.new(target.modules)}, &absorb/2)
        |> elem(0)
    end
  end

  defp absorb(batch, {set, mods}) do
    if Enum.any?(batch.modules, &(&1 in mods)),
      do: {[batch | set], MapSet.union(mods, MapSet.new(batch.modules))},
      else: {set, mods}
  end
end
