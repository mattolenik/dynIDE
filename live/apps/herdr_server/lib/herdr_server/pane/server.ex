defmodule HerdrServer.Pane.Server do
  @moduledoc """
  One per pane. Subscribes to its pty on init (so a restart resubscribes and gets a forced
  full damage), drains `dirty_rows` on `{:damage, ...}` into the shared row cache
  (`Pane.Rows`, with the cursor read on the same damage) and tells every registered client session `{:pane_damage, id, gen}`.
  Pane exit and title events go to `App.Store` by cast (the Store calls this process, so
  calling back would be a cycle). Kernel events carry the keeper id (`state.kernel_id`,
  from `Pane.Rows.kernel_id/1`); this process translates them to its pane id.

  This is the only caller of `dirty_rows/1` (one shared read cursor per vt).
  """
  use GenServer, restart: :transient

  require Logger

  alias HerdrServer.App.Store
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.{Rows, State}

  def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))

  defp via(id), do: {:via, Registry, {HerdrServer.Pane.Registry, id}}

  @doc "Resizes vt and pty (`cell_px` is the driving client's, may be nil) and repaints."
  @spec resize(pos_integer, pos_integer, pos_integer, {pos_integer, pos_integer} | nil) ::
          :ok | nil
  def resize(id, cols, rows, cell_px), do: call(id, {:resize, cols, rows, cell_px})

  @spec set_hidden(pos_integer, boolean) :: :ok | nil
  def set_hidden(id, hidden?), do: call(id, {:hidden, hidden?})

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
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt, pty: pty}} <- Kernel.keeper().lookup(kid) do
      kernel_ok(id, :subscribe, Kernel.pty().subscribe(pty, self()))
      {:ok, reload(%State{id: id, kernel_id: kid, vt: vt, pty: pty})}
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call({:resize, cols, rows, cell_px}, _from, state) do
    state = Map.merge(%State{}, state)
    kernel_ok(state.id, :vt_resize, Kernel.vt().resize(state.vt, cols, rows, cell_px))
    kernel_ok(state.id, :pty_resize, Kernel.pty().resize(state.pty, cols, rows, cell_px))
    {:reply, :ok, reload(state)}
  end

  def handle_call({:hidden, hidden?}, _from, state) do
    state = Map.merge(%State{}, state)
    kernel_ok(state.id, :set_hidden, Kernel.pty().set_hidden(state.pty, hidden?))
    state = %{state | hidden: hidden?}
    {:reply, :ok, if(hidden?, do: state, else: reload(state))}
  end

  @impl true
  def handle_info({:damage, kid, _gen}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)
    drain(kid)

    case Kernel.vt().dirty_rows(state.vt) do
      # no row changed: publish only if the cursor moved
      {gen, []} ->
        cursor = read_cursor(state.vt)

        {:noreply,
         if(cursor == state.cursor, do: state, else: publish(%{state | gen: gen}, cursor))}

      {gen, dirty} ->
        {:noreply, publish(%{state | gen: gen, rows: Enum.reduce(dirty, state.rows, &put_row/2)})}
    end
  end

  def handle_info({:exit, kid, _status}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)
    Store.event_async({:pane_exited, state.id})
    {:noreply, state}
  end

  def handle_info({:title, kid, title}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)
    Store.event_async({:pane_title, state.id, title})
    {:noreply, state}
  end

  def handle_info(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  # a kernel error is logged and the pane keeps running on its previous size/visibility
  defp kernel_ok(_id, _op, :ok), do: :ok

  defp kernel_ok(id, op, other) do
    Logger.warning("pane #{id}: #{op} failed: #{inspect(other)}")
    :error
  end

  # the scene's shapes are :block | :underline | :bar; a hollow block (unfocused) is a block
  defp read_cursor(vt) do
    case Kernel.vt().cursor(vt) do
      %{shape: :block_hollow} = c -> %{c | shape: :block}
      c -> c
    end
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

  defp publish(state, cursor \\ nil) do
    cursor = cursor || read_cursor(state.vt)
    :ok = Rows.put(state.id, state.gen, state.rows, cursor)
    msg = {:pane_damage, state.id, state.gen}

    Registry.dispatch(HerdrServer.Client.Registry, :clients, fn entries ->
      for {pid, _} <- entries, do: send(pid, msg)
    end)

    %{state | cursor: cursor}
  end
end
