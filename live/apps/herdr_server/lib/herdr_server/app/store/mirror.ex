defmodule HerdrServer.App.Store.Mirror do
  @moduledoc """
  The Store's mirror and rollback-restore helpers. They take and return the Store state as
  a plain map (never the struct), so an edit here recompiles this module only.

  `app.session`, `app.focus`, `app.ui` and the bookkeeping below (`@book`) are mirrored to
  `HerdrServer.Mirror`, debounced (one 20 ms timer; only changed entries are written).
  `Store.terminate/2` flushes, but it only runs when a callback raises: the Store does not
  trap exits, so a kill or a supervisor shutdown loses the window (Reconcile adopts its
  panes). Other app writes inside the window (focus, titles) are lost.
  """

  alias HerdrServer.App.Store

  # Store fields mirrored as {:store, key}; `hidden` is recomputed by settle/1
  @book [:driver, :driver_pid, :clients, :sizes]
  @flush_ms 20

  @doc "Schedules the debounced flush (`:flush` to self) unless one is pending."
  @spec dirty(map) :: map
  def dirty(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @flush_ms)}

  def dirty(state), do: state

  @doc "Writes the changed app and bookkeeping entries to the mirror."
  @spec flush(map) :: map
  def flush(%{app: nil} = state), do: state

  def flush(%{app: app} = state) do
    entries =
      Map.new(@book, &{{:store, &1}, Map.fetch!(state, &1)})
      |> Map.merge(Map.new([:session, :focus, :ui], &{{:app, &1}, Map.fetch!(app, &1)}))

    %{state | mirrored: HerdrServer.Mirror.put_changed(entries, state.mirrored)}
  end

  @doc "The mirrored bookkeeping fields that are set, as a map for the Store struct."
  @spec read_book() :: map
  def read_book do
    @book
    |> Map.new(&{&1, HerdrServer.Mirror.get({:store, &1})})
    |> Map.reject(&(elem(&1, 1) == nil))
  end

  @doc """
  The state to roll back to for a repeat failure of batch `k`: `{:ok, id, app}` where `app`
  is the reload server's `last_rolled_back/1` state_at_load (id `k` or older) with the
  current pane area, or `:none`.
  """
  @spec rollback_target(map, term) :: {:ok, pos_integer, map} | :none
  def rollback_target(%{app: app}, k) when is_integer(k) and app != nil do
    case last_rolled_back() do
      {:ok, id, at_load} when id <= k and at_load != nil ->
        {:ok, id, put_in(at_load.session.area, app.session.area)}

      _ ->
        :none
    end
  end

  def rollback_target(_state, _k), do: :none

  # A ref client re-fetches a pane only when its layout_gen changes: a restored older gen
  # (or an adopted pane's 0) would repeat one it has seen, with another size. Pane ids
  # spawned (and maybe closed) since the load must not be handed out again either.
  @doc "Keeps `next_id` and each pane's `layout_gen` at least their values in `app`."
  @spec keep_monotonic(map, map) :: map
  def keep_monotonic(restored, app) do
    gens = for {id, %{layout_gen: g}} <- app.session.panes, into: %{}, do: {id, g}
    restored = update_in(restored.session.next_id, &max(&1, app.session.next_id))

    update_in(restored.session.panes, fn panes ->
      Map.new(panes, fn {id, m} -> {id, %{m | layout_gen: max(m.layout_gen, gens[id] || 0)}} end)
    end)
  end

  # ponytail: a reload server dying between whereis and the call crashes the Store,
  # which then restarts from the mirror
  defp last_rolled_back do
    server = Store.reload_server()
    if GenServer.whereis(server), do: HerdrReload.Server.last_rolled_back(server), else: :none
  end
end
