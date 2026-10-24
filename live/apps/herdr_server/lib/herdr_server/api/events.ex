defmodule HerdrServer.Api.Events do
  @moduledoc """
  The event hub: one process between `App.Store` and the subscribed API connections.

  `subscribe/2` registers a connection pid with its filters and monitors it; the first
  subscription subscribes the hub itself to the Store. On each `{:app_changed, app}` the
  hub diffs against the last app (`Api.EventDiff`, guarded) and sends
  `{:api_event, event}` to each subscriber with a matching filter, at most once per event.
  The hub monitors the Store: after a Store restart it subscribes again (retrying every
  100 ms until the Store is registered) and diffs from the new Store's snapshot, so
  changes during the restart give no events. When the last subscriber goes, the hub
  unsubscribes from the Store and drops its copy of the app.
  A filter is `%{"type" => type}` plus any of `"workspace_id"`, `"tab_id"`, `"pane_id"`
  (public ids), each of which must equal the event's.

  Started with the API listener only (`:herdr_server, :api, :enabled`), after the Store.
  """
  use GenServer

  alias HerdrReload.Guard
  alias HerdrServer.Api.{EventDiff, Ids, View}
  alias HerdrServer.App.Store

  @ids ~w(workspace_id tab_id pane_id)

  @retry_ms 100

  defstruct subs: %{}, last: nil, store?: false, retry?: false

  @type filter :: %{required(String.t()) => String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends `pid` the events matching any of `filters` until `pid` exits."
  @spec subscribe(pid(), [filter()]) :: :ok
  def subscribe(pid, filters), do: GenServer.call(__MODULE__, {:subscribe, pid, filters})

  @doc """
  The `events.subscribe` handler, run in the connection process: every referenced id must
  exist (else `not_found`), then `conn` is subscribed and the router answers
  `{:subscribe, filters}`.
  """
  @spec request(map(), pid()) :: {:subscribe, [filter()]} | {:error, atom(), String.t()}
  def request(%{subscriptions: subs}, conn) do
    app = Store.snapshot()

    cond do
      msg = Enum.find_value(subs, &missing(app, &1)) ->
        {:error, :not_found, msg}

      GenServer.whereis(__MODULE__) == nil ->
        {:error, :not_available, "events are not served"}

      true ->
        filters = Enum.map(subs, &filter/1)
        :ok = subscribe(conn, filters)
        {:subscribe, filters}
    end
  end

  defp missing(app, sub) do
    Enum.find_value([:workspace_id, :tab_id, :pane_id], fn k ->
      id = sub[k]

      if id != nil and not exists?(app, k, id),
        do: "no such #{k |> Atom.to_string() |> String.trim_trailing("_id")} #{public(k, id)}"
    end)
  end

  defp exists?(nil, _k, _id), do: false
  defp exists?(app, :workspace_id, w), do: View.find_workspace(app, w) != nil
  defp exists?(app, :tab_id, {w, t}), do: View.find_tab(app, w, t) != nil
  defp exists?(app, :pane_id, p), do: View.pane(app, p) != nil

  defp public(:workspace_id, w), do: Ids.workspace(w)
  defp public(:tab_id, {w, t}), do: Ids.tab(w, t)
  defp public(:pane_id, p), do: Ids.pane(p)

  defp filter(sub) do
    for k <- [:workspace_id, :tab_id, :pane_id],
        (id = sub[k]) != nil,
        into: %{"type" => sub.type},
        do: {Atom.to_string(k), public(k, id)}
  end

  @doc "Whether `event` matches `filter`."
  @spec matches?(filter(), map()) :: boolean()
  def matches?(filter, event) do
    filter["type"] == event["event"] and
      Enum.all?(@ids, fn k -> not is_map_key(filter, k) or filter[k] == event[k] end)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:subscribe, pid, filters}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    subs =
      case state.subs do
        %{^pid => {ref, _}} -> Map.put(state.subs, pid, {ref, filters})
        subs -> Map.put(subs, pid, {Process.monitor(pid), filters})
      end

    {:reply, :ok, watch_store(%{state | subs: subs})}
  end

  @impl true
  def handle_info({:app_changed, app}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if state.subs != %{}, do: fan_out(state.last, app, state.subs)
    {:noreply, %{state | last: app}}
  end

  # the Store restarted: it forgot this subscription; subscribe again once it is back
  def handle_info({:DOWN, ref, :process, _, _}, %{store?: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, watch_store(%{state | store?: false, last: nil})}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    state = Map.merge(%__MODULE__{}, state)

    subs =
      case state.subs do
        %{^pid => {^ref, _}} -> Map.delete(state.subs, pid)
        subs -> subs
      end

    {:noreply, unwatch_store(%{state | subs: subs})}
  end

  def handle_info(:watch_store, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, watch_store(%{state | retry?: false})}
  end

  def handle_info(_msg, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  # The Store subscription is held only while someone subscribes. `store?` is the
  # Store's monitor ref; the snapshot is the base the first change diffs against.
  defp watch_store(%{subs: subs} = state) when subs == %{}, do: state
  defp watch_store(%{store?: ref} = state) when is_reference(ref), do: state

  defp watch_store(state) do
    # a Store that dies after answering is a DOWN (noproc at worst): subscribe again
    with pid when is_pid(pid) <- GenServer.whereis(Store),
         {:ok, app} <- store_subscribe() do
      %{state | store?: Process.monitor(pid), last: app}
    else
      _ -> retry_watch(state)
    end
  end

  # a Store between its exit and its restart answers nothing: try again shortly
  defp retry_watch(%{retry?: true} = state), do: state

  defp retry_watch(state) do
    Process.send_after(self(), :watch_store, @retry_ms)
    %{state | retry?: true}
  end

  # The Store going away mid-call is the one exit expected here; its DOWN follows.
  defp store_subscribe do
    :ok = Store.subscribe(self())
    {:ok, Store.snapshot()}
  catch
    :exit, {reason, {GenServer, :call, _}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      :error
  end

  defp unwatch_store(%{subs: subs, store?: ref} = state) when subs == %{} and is_reference(ref) do
    Process.demonitor(ref, [:flush])
    _ = store_unsubscribe()
    %{state | store?: false, last: nil}
  end

  defp unwatch_store(state), do: state

  defp store_unsubscribe do
    Store.unsubscribe(self())
  catch
    :exit, {reason, {GenServer, :call, _}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      :error
  end

  defp fan_out(old, new, subs) do
    case Guard.run_twice(EventDiff, :diff, [old, new], server: Store.reload_server(), scan: false) do
      {:ok, events} ->
        for event <- events,
            {pid, {_, filters}} <- subs,
            Enum.any?(filters, &matches?(&1, event)),
            do: send(pid, {:api_event, event})

        :ok

      {:failed, _} ->
        :ok
    end
  end
end
