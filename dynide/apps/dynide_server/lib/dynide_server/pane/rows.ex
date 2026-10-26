defmodule DynideServer.Pane.Rows do
  @moduledoc """
  The shared row cache `:dynide_pane_rows` (contract decision 3): one object per
  pane, `{pane_id, gen, rows_tuple, cursor}`, element n = packed row n, `cursor` the
  pane-relative cursor (`%{x, y, shape, visible}`) read on the same damage. `gen` is the
  content generation. Written only by `Pane.Server`; read by anyone via `fetch/1` (the
  attach ack's rows MFA), so a client gets rows and cursor in one lookup.

  Also `:dynide_pane_kernel`, `{pane_id, kernel_id}`: pane ids come from `App.Actions`,
  kernel ids from the keeper. Written by `App.Store` on open and close, read by
  `Pane.Server` and `Pane.Input` (any process, no call). Both tables are owned by
  `DynideServer.Mirror`; this module is a plain API with no process.
  """

  alias DynideServer.Pane.Facts

  @table :dynide_pane_rows
  @kernel :dynide_pane_kernel

  @spec fetch(pos_integer) :: {non_neg_integer, tuple, map | nil} | nil
  def fetch(pane_id) do
    case :ets.lookup(@table, pane_id) do
      [{^pane_id, gen, rows, cursor}] -> {gen, rows, cursor}
      [] -> nil
    end
  end

  @doc """
  Pane `pane_id`'s content generation, or nil. Never copies the rows. Hidden panes
  publish no damage, so their gen moves only once visible.
  """
  @spec gen(pos_integer) :: non_neg_integer | nil
  def gen(pane_id), do: :ets.lookup_element(@table, pane_id, 2, nil)

  @spec put(pos_integer, non_neg_integer, tuple, map | nil) :: :ok
  def put(pane_id, gen, rows, cursor) do
    :ets.insert(@table, {pane_id, gen, rows, cursor})
    :ok
  end

  @spec delete(pos_integer) :: :ok
  def delete(pane_id) do
    :ets.delete(@table, pane_id)
    :ets.delete(@kernel, pane_id)
    Facts.delete(pane_id)
    DynideServer.Mirror.delete({:pane, pane_id})
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
  end

  @doc "Every `{pane_id, kernel_id}`."
  @spec kernel_ids() :: [{pos_integer, pos_integer}]
  def kernel_ids, do: :ets.tab2list(@kernel)
end
