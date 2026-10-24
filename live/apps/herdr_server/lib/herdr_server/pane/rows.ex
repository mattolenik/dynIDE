defmodule HerdrServer.Pane.Rows do
  @moduledoc """
  Owner of the shared row cache `:herdr_pane_rows` (contract decision 3): one object per
  pane, `{pane_id, gen, rows_tuple, cursor}`, element n = packed row n, `cursor` the
  pane-relative cursor (`%{x, y, shape, visible}`) read on the same damage. `gen` is the
  content generation. Written only by `Pane.Server`; read by anyone via `fetch/1` (the
  attach ack's rows MFA), so a client gets rows and cursor in one lookup.

  Also owns `:herdr_pane_kernel`, `{pane_id, kernel_id}`: pane ids come from `App.Actions`,
  kernel ids from the keeper. Written by `App.Store` on open and close, read by
  `Pane.Server` and `Pane.Input` (any process, no call).
  """
  use GenServer

  @table :herdr_pane_rows
  @kernel :herdr_pane_kernel

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
    :ets.delete(@kernel, pane_id)
    :ok
  end

  @spec put_kernel_id(pos_integer, pos_integer) :: :ok
  def put_kernel_id(pane_id, kernel_id) do
    :ets.insert(@kernel, {pane_id, kernel_id})
    :ok
  end

  @doc "The keeper id of pane `pane_id`, or nil."
  @spec kernel_id(pos_integer) :: pos_integer | nil
  def kernel_id(pane_id) do
    case :ets.lookup(@kernel, pane_id) do
      [{^pane_id, kid}] -> kid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Every `{pane_id, kernel_id}`."
  @spec kernel_ids() :: [{pos_integer, pos_integer}]
  def kernel_ids, do: :ets.tab2list(@kernel)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # ponytail: lost if this process restarts (panes then stop taking input); M4's ETS mirror
    :ets.new(@kernel, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
