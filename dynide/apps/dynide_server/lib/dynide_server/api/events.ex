defmodule DynideServer.Api.Events do
  @moduledoc """
  The event hub: one process between `App.Store` and the subscribed API connections.

  `subscribe/2` registers a connection pid with its filters and monitors it; the first
  subscription subscribes the hub itself to the Store. On each `{:app_changed, app}` the
  hub diffs against the last app (`Api.EventDiff`, guarded) and sends
  `{:api_event, event}` to each subscriber with a matching filter, at most once per event.
  The Store's `{:alert, a}` becomes `notification.shown`, placed in the last app. The
  Store's `{:api_event, ev}` (a move, `EventDiff.moved/2`) arrives ahead of its app: it
  waits in `pending` and goes out after that app's diff, placed in it; a Store restart
  or the last unsubscribe drops it.
  The hub monitors the Store: after a Store restart it subscribes again (retrying every
  100 ms until the Store is registered) and diffs from the new Store's snapshot, so
  changes during the restart give no events. When the last subscriber goes, the hub
  unsubscribes from the Store and drops its copy of the app.
  A filter is `%{"type" => type}` plus any of `"workspace_id"`, `"tab_id"`, `"pane_id"`
  (public ids), each of which must equal the event's.

  Started with the API listener only (`:dynide_server, :api, :enabled`), after the Store.
  """
  use GenServer

  alias DynideReload.Guard
  alias DynideServer.Api.{EventDiff, Ids, View}
  alias DynideServer.App.{Commands, Store}

  @ids ~w(workspace_id tab_id pane_id)

  @retry_ms 100

  defstruct subs: %{}, last: nil, store?: false, retry?: false, pending: []

  @type filter :: %{required(String.t()) => String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends `pid` the events matching any of `filters` until `pid` exits."
  @spec subscribe(pid(), [filter()]) :: :ok
  def subscribe(pid, filters), do: GenServer.call(__MODULE__, {:subscribe, pid, filters})

  @doc "Stops sending `pid` events; the last subscriber gone, the hub stops watching the Store."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

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

  @doc """
  The `events.wait` handler: subscribe the connection to a single `match_event` filter,
  then poll until a matching event arrives or `timeout_ms` elapses. The continuation
  holds only data (the filter, deadline and hub monitor), so a reload moves a running
  wait onto new code; the subscription is dropped when the wait answers. The hub is
  monitored: a hub that stops answers `events_lost`, like a stream.
  """
  @spec wait(map(), pid()) ::
          {:continue, {module(), atom(), list()}} | {:ok, map()} | {:error, atom(), String.t()}
  def wait(%{match_event: match} = params, conn) do
    app = Store.snapshot()

    cond do
      msg = missing(app, match) ->
        {:error, :not_found, msg}

      GenServer.whereis(__MODULE__) == nil ->
        {:error, :not_available, "events are not served"}

      true ->
        filter = match_filter(match)
        :ok = subscribe(conn, [filter])
        deadline = params[:timeout_ms] && System.monotonic_time(:millisecond) + params.timeout_ms
        ref = Process.monitor(Process.whereis(__MODULE__))
        poll_wait(%{filter: filter, deadline: deadline, hub: ref}, nil)
    end
  end

  @doc false
  def poll_wait(state, _ctx) do
    case receive_match(state.filter, state.hub) do
      {:ok, event} ->
        finish_wait(state)
        {type, data} = Map.pop(event, "event")
        {:ok, %{type: "event_wait", event: type, data: data}}

      :down ->
        Process.demonitor(state.hub, [:flush])
        {:error, :events_lost, "the event hub stopped"}

      :none ->
        if state.deadline && System.monotonic_time(:millisecond) >= state.deadline do
          finish_wait(state)
          {:error, :timeout, "no matching event in time"}
        else
          {:continue, {__MODULE__, :poll_wait, [state]}}
        end
    end
  end

  defp receive_match(filter, hub) do
    receive do
      {:api_event, event} ->
        if matches?(filter, event), do: {:ok, event}, else: receive_match(filter, hub)

      {:DOWN, ^hub, :process, _, _} ->
        :down
    after
      0 -> :none
    end
  end

  # the hub may have stopped just after it delivered the event: an unsubscribe is then a
  # noproc, and the consumed event must still answer rather than be re-polled away
  defp finish_wait(state) do
    Process.demonitor(state.hub, [:flush])
    safe_unsubscribe(self())
  end

  defp safe_unsubscribe(pid) do
    unsubscribe(pid)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown, :killed] -> :ok
  end

  defp match_filter(match) do
    for k <- [:workspace_id, :tab_id, :pane_id],
        (id = match[k]) != nil,
        into: %{"type" => match.event},
        do: {Atom.to_string(k), public(k, id)}
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

  def handle_call({:unsubscribe, pid}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {sub, subs} = Map.pop(state.subs, pid)
    if sub, do: Process.demonitor(elem(sub, 0), [:flush])
    {:reply, :ok, unwatch_store(%{state | subs: subs})}
  end

  @impl true
  def handle_info({:app_changed, app}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if state.subs != %{}, do: fan_out(state.last, app, state.subs)
    moved(Enum.reverse(state.pending), app, state.subs)
    {:noreply, %{state | last: app, pending: []}}
  end

  # a move, published with the app that follows it
  def handle_info({:api_event, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)

    if state.subs == %{},
      do: {:noreply, state},
      else: {:noreply, %{state | pending: [ev | state.pending]}}
  end

  # an agent alert (the Store's `{:alert, a}`), placed in the last app
  def handle_info({:alert, %{kind: :notification} = a}, state) do
    state = Map.merge(%__MODULE__{}, state)

    with %{} <- state.last,
         {:ok, {w, t}} <- locate(state.last, a.pane) do
      event = %{
        "event" => "notification.shown",
        "workspace_id" => Ids.workspace(w),
        "tab_id" => Ids.tab(w, t),
        "pane_id" => Ids.pane(a.pane),
        "level" => Atom.to_string(a.level),
        "title" => a.title,
        "body" => a.body,
        "sound" => Atom.to_string(a.sound)
      }

      for {pid, {_, filters}} <- state.subs,
          Enum.any?(filters, &matches?(&1, event)),
          do: send(pid, {:api_event, event})
    end

    {:noreply, state}
  end

  # the Store restarted: it forgot this subscription; subscribe again once it is back
  def handle_info({:DOWN, ref, :process, _, _}, %{store?: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, watch_store(%{state | store?: false, last: nil, pending: []})}
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
    %{state | store?: false, last: nil, pending: []}
  end

  defp unwatch_store(state), do: state

  defp store_unsubscribe do
    Store.unsubscribe(self())
  catch
    :exit, {reason, {GenServer, :call, _}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      :error
  end

  defp locate(app, pane),
    do:
      Guard.run_twice(Commands, :locate, [app, pane], server: Store.reload_server(), scan: false)

  defp moved(evs, app, subs) do
    for ev <- evs,
        {:ok, %{} = event} <-
          [
            Guard.run_twice(EventDiff, :moved, [ev, app],
              server: Store.reload_server(),
              scan: false
            )
          ],
        {pid, {_, filters}} <- subs,
        Enum.any?(filters, &matches?(&1, event)),
        do: send(pid, {:api_event, event})

    :ok
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
