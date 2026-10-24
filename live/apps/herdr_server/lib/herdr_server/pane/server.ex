defmodule HerdrServer.Pane.Server do
  @moduledoc """
  One per pane. Subscribes to its pty on init (so a restart resubscribes and gets a forced
  full damage), drains `dirty_rows` on `{:damage, ...}` into the shared row cache
  (`Pane.Rows`) and tells every registered client session `{:pane_damage, id, gen}`.
  Pane exit and title events go to `App.Store` by cast (the Store calls this process, so
  calling back would be a cycle).
  """
  use GenServer, restart: :transient

  require Logger

  alias HerdrServer.App.Store
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.{Rows, State}

  def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))

  defp via(id), do: {:via, Registry, {HerdrServer.Pane.Registry, id}}

  @doc "Resizes vt and pty and repaints the row cache in full."
  @spec resize(pos_integer, pos_integer, pos_integer) :: :ok | nil
  def resize(id, cols, rows), do: call(id, {:resize, cols, rows})

  @spec set_hidden(pos_integer, boolean) :: :ok | nil
  def set_hidden(id, hidden?), do: call(id, {:hidden, hidden?})

  @doc "Cursor relative to the pane grid; nil if the pane is gone."
  @spec cursor(pos_integer) :: map | nil
  def cursor(id), do: call(id, :cursor)

  defp call(id, msg) do
    GenServer.call(via(id), msg)
  catch
    # the pane closed under us; callers treat it as absent
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      nil

    # a pane stuck behind its vt must not take the caller (the Store) down
    :exit, {:timeout, _} ->
      Logger.warning("pane #{id}: #{inspect(msg)} timed out")
      nil
  end

  @impl true
  def init(id) do
    case Kernel.keeper().lookup(id) do
      {:ok, %{vt: vt, pty: pty}} ->
        :ok = Kernel.pty().subscribe(pty, self())
        {:ok, reload(%State{id: id, vt: vt, pty: pty})}

      :error ->
        :ignore
    end
  end

  @impl true
  def handle_call({:resize, cols, rows}, _from, state) do
    state = Map.merge(%State{}, state)
    :ok = Kernel.vt().resize(state.vt, cols, rows, nil)
    :ok = Kernel.pty().resize(state.pty, cols, rows, nil)
    {:reply, :ok, reload(state)}
  end

  def handle_call({:hidden, hidden?}, _from, state) do
    state = Map.merge(%State{}, state)
    :ok = Kernel.pty().set_hidden(state.pty, hidden?)
    state = %{state | hidden: hidden?}
    {:reply, :ok, if(hidden?, do: state, else: reload(state))}
  end

  def handle_call(:cursor, _from, state) do
    state = Map.merge(%State{}, state)
    {:reply, Kernel.vt().cursor(state.vt), state}
  end

  @impl true
  def handle_info({:damage, id, _gen}, state) do
    state = Map.merge(%State{}, state)
    drain(id)

    case Kernel.vt().dirty_rows(state.vt) do
      {_gen, []} ->
        {:noreply, state}

      {gen, dirty} ->
        {:noreply, publish(%{state | gen: gen, rows: Enum.reduce(dirty, state.rows, &put_row/2)})}
    end
  end

  def handle_info({:exit, id, _status}, state) do
    state = Map.merge(%State{}, state)
    Store.event_async({:pane_exited, id})
    {:noreply, state}
  end

  def handle_info({:title, id, title}, state) do
    state = Map.merge(%State{}, state)
    Store.event_async({:pane_title, id, title})
    {:noreply, state}
  end

  def handle_info(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  defp put_row({n, b}, t) when n < tuple_size(t), do: put_elem(t, n, b)
  defp put_row(_row, t), do: t

  # coalesce: one drain covers every damage already queued
  defp drain(id) do
    receive do
      {:damage, ^id, _} -> drain(id)
    after
      0 -> :ok
    end
  end

  defp reload(state) do
    {gen, rows} = Kernel.vt().full_rows(state.vt)
    publish(%{state | gen: gen, rows: rows |> Enum.map(&elem(&1, 1)) |> List.to_tuple()})
  end

  defp publish(state) do
    :ok = Rows.put(state.id, state.gen, state.rows)
    msg = {:pane_damage, state.id, state.gen}

    Registry.dispatch(HerdrServer.Client.Registry, :clients, fn entries ->
      for {pid, _} <- entries, do: send(pid, msg)
    end)

    state
  end
end
