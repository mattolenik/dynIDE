defmodule HerdrServer.Pane.Rows do
  @moduledoc """
  Owner of the shared row cache `:herdr_pane_rows` (contract decision 3): one object per
  pane, `{pane_id, gen, rows_tuple, cursor}`, element n = packed row n, `cursor` the
  pane-relative cursor (`%{x, y, shape, visible}`) read on the same damage. `gen` is the
  content generation. Written only by `Pane.Server`; read by anyone via `fetch/1` (the
  attach ack's rows MFA), so a client gets rows and cursor in one lookup.
  """
  use GenServer

  @table :herdr_pane_rows

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec fetch(pos_integer) :: {non_neg_integer, tuple, map | nil} | nil
  def fetch(pane_id) do
    case lookup(pane_id) do
      [{^pane_id, gen, rows, cursor}] -> {gen, rows, cursor}
      [] -> nil
    end
  end

  # the table is briefly missing while this process restarts
  defp lookup(pane_id) do
    :ets.lookup(@table, pane_id)
  rescue
    ArgumentError -> []
  end

  @spec put(pos_integer, non_neg_integer, tuple, map | nil) :: :ok
  def put(pane_id, gen, rows, cursor) do
    :ets.insert(@table, {pane_id, gen, rows, cursor})
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
