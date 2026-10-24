defmodule HerdrServer.App.Restore do
  @moduledoc """
  Pane bookkeeping for `App.Store` across its restarts: closing panes, and adopting the
  panes a mirrored app (`HerdrServer.Mirror.app/0`) still has.
  """

  alias HerdrServer.Kernel
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Pane.Supervisor, as: Panes

  @doc """
  Adopts the live panes of `app` and returns the ids of the panes to drop (the Store
  closes them as `{:pane_exited, id}`). A pane is live when its kernel id is mapped in
  `Pane.Rows` and still held by the keeper; its `Pane.Server` is restarted if missing.
  Keeper panes no app pane maps, and mapped ids the app does not know, are closed.
  """
  # ponytail: placeholder until P5's Reconcile.run/2 replaces it
  @spec adopt(%{session: %{panes: map}}) :: [pos_integer]
  def adopt(app) do
    keeper = Kernel.keeper()
    live = MapSet.new(keeper.ids())
    mapped = Map.new(Rows.kernel_ids())

    {kept, dropped} =
      app.session.panes |> Map.keys() |> Enum.split_with(&MapSet.member?(live, mapped[&1]))

    for {id, _} <- mapped, not Map.has_key?(app.session.panes, id), do: close(id)
    owned = MapSet.new(kept, &mapped[&1])
    for kid <- live, not MapSet.member?(owned, kid), do: keeper.close(kid)

    for id <- kept, Registry.lookup(HerdrServer.Pane.Registry, id) == [], do: Panes.start_pane(id)

    dropped
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
