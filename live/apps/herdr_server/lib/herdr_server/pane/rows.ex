defmodule HerdrServer.Pane.Rows do
  @moduledoc """
  Owner of the shared row cache `:herdr_pane_rows` (contract decision 3): one object per
  pane, `{pane_id, gen, rows_tuple}`, element n = packed row n. Written only by
  `Pane.Server`; read by anyone via `fetch/1` (the attach ack's rows MFA).
  """
  use GenServer

  @table :herdr_pane_rows

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec fetch(pos_integer) :: {non_neg_integer, tuple} | nil
  def fetch(pane_id) do
    case :ets.lookup(@table, pane_id) do
      [{^pane_id, gen, rows}] -> {gen, rows}
      [] -> nil
    end
  end

  @spec put(pos_integer, non_neg_integer, tuple) :: :ok
  def put(pane_id, gen, rows) do
    :ets.insert(@table, {pane_id, gen, rows})
    :ok
  end

  @spec delete(pos_integer) :: :ok
  def delete(pane_id) do
    :ets.delete(@table, pane_id)
    :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
