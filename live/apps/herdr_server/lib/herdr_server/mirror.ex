defmodule HerdrServer.Mirror do
  @moduledoc """
  Owner of every server ETS table, so a crash of the processes that write them loses
  nothing. Started right after `Native.Keeper`; its only code is `init/1` (no
  `handle_call`/`handle_cast`: nothing calls it, so it has nothing to crash on).

    * `:herdr_pane_rows`, `:herdr_pane_kernel`: the row cache and pane -> kernel id map
      (API in `Pane.Rows`).
    * `:herdr_mirror`: state a restarted process reads back. Keys:
      `{:app, :session | :focus | :ui}` and `{:store, key}` (written by `App.Store`,
      debounced), `{:pane, id}` (`Pane.Server`, `%{hidden: boolean}`),
      `{:client, client_pid}` (`Client.Session`, presentation fields of `Client.State`).

  The functions below are plain ETS reads and writes; they run in the caller.
  """
  use GenServer

  @mirror :herdr_mirror

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    for t <- [:herdr_pane_rows, :herdr_pane_kernel, @mirror],
        do: :ets.new(t, [:named_table, :public, :set, read_concurrency: true])

    {:ok, nil}
  end

  @doc "The mirrored app (`%{session, focus, ui}`), or nil when any part is missing."
  @spec app() :: map | nil
  def app do
    with s when s != nil <- get({:app, :session}),
         f when f != nil <- get({:app, :focus}),
         u when u != nil <- get({:app, :ui}),
         do: %{session: s, focus: f, ui: u}
  end

  @spec pane(pos_integer) :: map | nil
  def pane(id), do: get({:pane, id})

  @spec client(pid) :: map | nil
  def client(pid), do: get({:client, pid})

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
