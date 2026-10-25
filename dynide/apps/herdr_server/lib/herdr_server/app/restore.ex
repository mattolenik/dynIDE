defmodule HerdrServer.App.Restore do
  @moduledoc """
  Pane bookkeeping for `App.Store` across its restarts and state restores: the live pane
  set `App.Reconcile` works against, starting missing `Pane.Server`s, closing panes.

  In a VM that adopted panes from the handoff broker (`Handoff.Link.adopt_reason/0` not
  nil) a keeper pane nothing maps may be an adopted child (ctl-opened, or spawned just
  before the crash): `dynide/0` and `close_all/0` never close one there.
  """

  alias HerdrServer.Handoff.Link

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
    if not adopted?(), do: for(kid <- kids, not MapSet.member?(owned, kid), do: keeper.close(kid))
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

  @doc """
  Closes every pane mapped in `Pane.Rows`, then anything else the keeper holds. In an
  adopted VM it closes no keeper pane: it stops the pane servers and forgets the map.
  Returns how many live panes it closed or orphaned (keeper panes closed, or in an adopted
  VM mapped keeper panes forgotten), so the Store can report a session loss.
  """
  @spec close_all() :: non_neg_integer
  def close_all do
    mapped = Rows.kernel_ids()
    keeper = Kernel.keeper()
    held = keeper.ids()

    if adopted?() do
      Enum.each(mapped, fn {id, _kid} ->
        Panes.stop_pane(id)
        Rows.delete(id)
      end)

      Enum.count(mapped, fn {_id, kid} -> kid in held end)
    else
      Enum.each(mapped, fn {id, _kid} -> close(id) end)
      Enum.each(keeper.ids(), &keeper.close/1)
      length(held)
    end
  end

  defp adopted?, do: Link.adopt_reason() != nil
end
