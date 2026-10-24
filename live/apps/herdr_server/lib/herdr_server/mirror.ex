defmodule HerdrServer.Mirror do
  @moduledoc """
  Owner of every server ETS table, so a crash of the processes that write them loses
  nothing. Started right after `Native.Keeper`. A bare `:proc_lib` process, not a
  GenServer: it creates the tables, then hibernates and drops every message it gets
  (calls, casts, system messages), so nothing sent to it can stop it. Hibernating
  between messages keeps no stack in this module, so reloading it twice does not purge
  (kill) the owner. It only stops with its supervisor (an exit signal).

    * `:herdr_pane_rows`, `:herdr_pane_kernel`: the row cache and pane -> kernel id map
      (API in `Pane.Rows`).
    * `:herdr_pane_facts`: per-pane terminal facts, host colours and the foreground
      client (API in `Pane.Facts`).
    * `:herdr_mirror`: state a restarted process reads back. Keys:
      `{:app, :session | :focus | :ui}` and `{:store, key}` (written by `App.Store`,
      debounced), `{:pane, id}` (`Pane.Server`, `%{hidden: boolean}`),
      `{:client, client_pid}` (`Client.Session`, presentation fields of `Client.State`),
      `:runtime_status` (`ReloadNotices`, the `RuntimeStatus` a new session starts with).

  The functions below are plain ETS reads and writes; they run in the caller.
  """

  @mirror :herdr_mirror

  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

  @spec start_link(term) :: {:ok, pid}
  def start_link(_), do: :proc_lib.start_link(__MODULE__, :init, [])

  @doc false
  def init do
    true = Process.register(self(), __MODULE__)

    for t <- [:herdr_pane_rows, :herdr_pane_kernel, :herdr_pane_facts, @mirror],
        do: :ets.new(t, [:named_table, :public, :set, read_concurrency: true])

    :proc_lib.init_ack({:ok, self()})
    :proc_lib.hibernate(__MODULE__, :wake, [])
  end

  @doc false
  # woken by a message: drop it and sleep again
  def wake do
    receive do
      _ -> :ok
    end

    :proc_lib.hibernate(__MODULE__, :wake, [])
  end

  @doc "The mirrored app (`%{session, focus, ui}`), or nil when any part is missing."
  @spec app() :: map | nil
  def app do
    # also the reload server's state_at_load provider, which may run before the table exists
    with true <- :ets.whereis(@mirror) != :undefined,
         s when s != nil <- get({:app, :session}),
         f when f != nil <- get({:app, :focus}),
         u when u != nil <- get({:app, :ui}),
         do: %{session: s, focus: f, ui: u},
         else: (_ -> nil)
  end

  @spec pane(pos_integer) :: map | nil
  def pane(id), do: get({:pane, id})

  @spec client(pid) :: map | nil
  def client(pid), do: get({:client, pid})

  @doc "Every client pid with a mirror entry."
  @spec clients() :: [pid]
  def clients, do: for([pid] <- :ets.match(@mirror, {{:client, :"$1"}, :_}), do: pid)

  @spec get(term) :: term | nil
  def get(key) do
    case :ets.lookup(@mirror, key) do
      [{^key, v}] -> v
      [] -> nil
    end
  end

  @spec put(term, term) :: :ok
  def put(key, value) do
    :ets.insert(@mirror, {key, value})
    :ok
  end

  @spec delete(term) :: :ok
  def delete(key) do
    :ets.delete(@mirror, key)
    :ok
  end

  @doc "Writes every entry of `new` whose value differs from `last`; returns `new`."
  @spec put_changed(map, map) :: map
  def put_changed(new, last) do
    for {k, v} <- new, Map.fetch(last, k) != {:ok, v}, do: put(k, v)
    new
  end
end
