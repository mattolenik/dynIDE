defmodule HerdrServer.Pane.Facts do
  @moduledoc """
  Per-pane terminal facts in `:herdr_pane_facts` (owned by `HerdrServer.Mirror`), so
  any process reads them without a call and a restarted `Pane.Server` gets them back.

  Keys: a pane id -> `t:facts/0`, written only by that pane's `Pane.Server`;
  `:host_colors` -> the foreground client's colour caps (`%{colors, scheme}`, either
  key optional), applied by every `Pane.Server` on init; `:foreground` -> the
  foreground client session pid (`Client.Foreground`).

  `scroll` is the vt's scrollbar (`total`, `viewport`, `offset` = top row of the
  viewport); `scrolled` is true while the viewport is above the bottom. Plain ETS API,
  no process.
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
    case :ets.lookup(@table, key) do
      [{^key, v}] -> v
      [] -> nil
    end
  end

  @spec put(pos_integer | atom, term) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  @spec delete(pos_integer) :: :ok
  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end

  @doc "Whether pane `id` is scrolled back (one ETS lookup; the input fast path uses it)."
  @spec scrolled?(pos_integer) :: boolean
  def scrolled?(id), do: match?([{_, %{scrolled: true}}], :ets.lookup(@table, id))

  @spec host_colors() :: map | nil
  def host_colors, do: get(:host_colors)

  @doc "Merges `caps`' `:colors` and `:scheme` (whichever are present) into the host colours."
  @spec put_host_colors(map) :: :ok
  def put_host_colors(caps) do
    put(:host_colors, Map.merge(host_colors() || %{}, Map.take(caps, [:colors, :scheme])))
  end
end
