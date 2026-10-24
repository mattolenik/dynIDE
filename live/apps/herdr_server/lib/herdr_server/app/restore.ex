defmodule HerdrServer.App.Restore do
  @moduledoc """
  Pane bookkeeping for `App.Store` across its restarts and state restores: the live pane
  set `App.Reconcile` works against, starting missing `Pane.Server`s, closing panes.
  """

  alias HerdrServer.Kernel
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Pane.Supervisor, as: Panes

  @doc """
  The live panes, `%{pane_id => kernel_id}`: mapped in `Pane.Rows` and still held by the
  keeper. Mappings whose kernel is gone are closed, and so are keeper panes no pane maps
  (a spawn interrupted between open and mapping): nothing can reach them.
  """
  @spec live() :: %{pos_integer => pos_integer}
  def live do
    keeper = Kernel.keeper()
    kids = MapSet.new(keeper.ids())
    {live, stale} = Enum.split_with(Rows.kernel_ids(), &MapSet.member?(kids, elem(&1, 1)))
    Enum.each(stale, &close(elem(&1, 0)))
    owned = MapSet.new(live, &elem(&1, 1))
    for kid <- kids, not MapSet.member?(owned, kid), do: keeper.close(kid)
    Map.new(live)
  end

  @doc "Starts pane `id`'s `Pane.Server` unless it runs."
  @spec ensure_server(pos_integer) :: :ok
  def ensure_server(id) do
    if Registry.lookup(HerdrServer.Pane.Registry, id) == [], do: Panes.start_pane(id)
    :ok
  end

  @doc "Closes pane `id`: its server, its kernel pane and its rows. Idempotent."
  @spec close(pos_integer) :: :ok
  def close(id) do
    Panes.stop_pane(id)
    kid = Rows.kernel_id(id)
    if kid, do: Kernel.keeper().close(kid)
    Rows.delete(id)
  end

  @doc "Closes every pane mapped in `Pane.Rows`, then anything else the keeper holds."
  @spec close_all() :: :ok
  def close_all do
    Enum.each(Rows.kernel_ids(), fn {id, _kid} -> close(id) end)
    keeper = Kernel.keeper()
    Enum.each(keeper.ids(), &keeper.close/1)
  end
end
