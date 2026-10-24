defmodule HerdrServer.Native.Keeper do
  @moduledoc """
  Owns every kernel resource (vt and pty) and the pane-id table. Everything
  else refers to panes by id and reads the table from ETS (`lookup/1`).

  A bad spec or a raising NIF returns an error instead of crashing the Keeper:
  a crash would lose the table and SIGHUP every pane.

  Handoff (`HerdrServer.Handoff`): `init` adopts the panes a previous VM left with the
  broker, `open` hands the broker a dup of each new master before replying, and
  `prepare/0`, `thaw/0`, `release/0` run the old VM's side of a graceful restart.
  """
  use GenServer

  require Logger
  require HerdrServer.Native.Vt
  alias HerdrServer.Handoff.{Link, Snapshotter, State}
  alias HerdrServer.Native.{Pty, Vt}

  @table __MODULE__
  @escalate_ms 2000
  @keys [:cmd, :args, :env, :cwd, :cols, :rows, :max_scrollback, :subscriber]

  # closing: id => pty, kept after `close/1` until the SIGKILL escalation.
  # pending: id => input taken by `prepare/0`, written back by `thaw/0`.
  defstruct next_id: 1, closing: %{}, pending: %{}

  @type id :: pos_integer
  @typedoc "`max_scrollback` is in bytes (e.g. 10_000_000); cols and rows are in 1..65535."
  @type spec :: %{
          cmd: binary,
          args: [binary],
          env: [{binary, binary}],
          cwd: binary | nil,
          cols: pos_integer,
          rows: pos_integer,
          max_scrollback: non_neg_integer,
          subscriber: pid | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Creates the vt and pty for `spec` and returns the new pane id.
  `{:error, {:invalid_spec, key}}` for a missing or ill-typed key,
  `{:error, Pty.spawn_error()}` when the spawn fails, `{:error, {:raise, message}}`
  when a NIF raises.
  """
  @spec open(spec) :: {:ok, id} | {:error, term}
  def open(spec) do
    with :ok <- check(spec), do: GenServer.call(__MODULE__, {:open, spec})
  end

  @spec lookup(id) ::
          {:ok,
           %{vt: Vt.vt(), pty: Pty.pty(), os_pid: pos_integer, max_scrollback: non_neg_integer}}
          | :error
  def lookup(id) do
    case :ets.lookup(@table, id) do
      [{^id, row}] -> {:ok, row}
      [] -> :error
    end
  end

  @doc """
  Sends SIGHUP and removes the pane from the table; SIGKILL follows after 2 s
  (a no-op if the child was already reaped). The exit event still follows.
  """
  @spec close(id) :: :ok
  def close(id), do: GenServer.call(__MODULE__, {:close, id})

  @spec ids() :: [id]
  def ids, do: @table |> :ets.select([{{:"$1", :_}, [], [:"$1"]}]) |> Enum.sort()

  @doc """
  Old VM, graceful restart: pauses the Snapshotter, freezes every pane and sends its
  final state (with the unwritten input) to the broker.
  """
  @spec prepare() :: :ok
  def prepare, do: GenServer.call(__MODULE__, :prepare, :infinity)

  @doc "Restart aborted: restarts every pane, its taken input first, and the Snapshotter."
  @spec thaw() :: :ok
  def thaw, do: GenServer.call(__MODULE__, :thaw, :infinity)

  @doc "Restart done: the new VM owns the children; never signal them again."
  @spec release() :: :ok
  def release, do: GenServer.call(__MODULE__, :release, :infinity)

  @doc false
  # Adopts `{"pane/<id>", blob, [fd]}` entries as `init` does (no redraw nudge).
  @spec adopt_entries([{binary, binary, [Pty.fd()]}]) :: :ok
  def adopt_entries(entries), do: GenServer.call(__MODULE__, {:adopt, entries, nil}, :infinity)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, adopt(Link.take_adopted("pane/"), Link.adopt_reason(), %__MODULE__{})}
  end

  @impl true
  def handle_call({:open, spec}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    id = state.next_id

    with :ok <- check(spec), :ok <- start(id, spec) do
      # before replying (ruling 3): a kill -9 after open returns cannot lose the pane
      if Link.enabled?() do
        {:ok, row} = lookup(id)
        Link.hold(key(id), State.encode(State.build(id, row, vt: false)), [row.pty])
      end

      {:reply, {:ok, id}, %{state | next_id: id + 1}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:close, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    case lookup(id) do
      {:ok, %{pty: pty}} ->
        Pty.kill(pty, :hup)
        :ets.delete(@table, id)
        Link.drop(key(id))
        Process.send_after(self(), {:escalate, id}, @escalate_ms)
        {:reply, :ok, %{state | closing: Map.put(state.closing, id, pty)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:adopt, entries, reason}, _from, state) do
    {:reply, :ok, adopt(entries, reason, Map.merge(%__MODULE__{}, state))}
  end

  def handle_call(:prepare, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    :ok = Snapshotter.pause()

    pending =
      Map.new(rows(), fn {id, row} ->
        Pty.freeze(row.pty)
        pending = Pty.take_pending(row.pty)
        final_update(id, row, pending)
        {id, pending}
      end)

    {:reply, :ok, %{state | pending: pending}}
  end

  def handle_call(:thaw, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    for {id, row} <- rows() do
      Pty.thaw(row.pty)

      case Map.get(state.pending, id, "") do
        "" -> :ok
        bytes -> write_pending(id, row.pty, bytes)
      end
    end

    :ok = Snapshotter.resume()
    {:reply, :ok, %{state | pending: %{}}}
  end

  def handle_call(:release, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    for {_id, row} <- rows(), do: Pty.release(row.pty)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:escalate, id}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {pty, closing} = Map.pop(state.closing, id)
    if pty, do: Pty.kill(pty, :kill)
    {:noreply, %{state | closing: closing}}
  end

  def handle_info(_msg, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  defp key(id), do: "pane/#{id}"
  defp rows, do: :ets.tab2list(@table)

  defp final_update(id, row, pending) do
    Link.update(key(id), State.encode(State.build(id, row, pending_input: pending)))
  rescue
    # ghostty refused the snapshot: the broker keeps the last periodic one
    e in ErlangError ->
      Logger.warning("handoff: final state of pane #{id} lost: #{Exception.message(e)}")
  end

  defp write_pending(id, pty, bytes) do
    with {:error, reason} <- Pty.write(pty, bytes),
         do: Logger.warning("handoff: pane #{id} lost #{byte_size(bytes)} input bytes: #{reason}")
  end

  defp adopt(entries, reason, state) do
    Enum.reduce(entries, state, fn {key, blob, fds}, state ->
      with "pane/" <> sid <- key,
           {id, ""} <- Integer.parse(sid),
           {:ok, %{id: ^id} = st} <- State.decode(blob),
           [fd] <- fds,
           :ok <- adopt_one(id, st, fd, reason) do
        %{state | next_id: max(state.next_id, id + 1)}
      else
        err ->
          Logger.warning("handoff: pane #{key} not adopted: #{inspect(err, limit: 5)}")
          Link.unclaim(key)
          state
      end
    end)
  end

  defp adopt_one(id, st, fd, reason) do
    vt = restore_vt(id, st)

    with {:ok, pty} <- Pty.adopt(vt, id, fd, st.os_pid, st.exited != nil, st.title, st.pwd) do
      :ets.insert(
        @table,
        {id, %{vt: vt, pty: pty, os_pid: st.os_pid, max_scrollback: st.max_scrollback}}
      )

      if st.hidden, do: Pty.set_hidden(pty, true)
      if st.pending_input != "", do: write_pending(id, pty, st.pending_input)
      if reason == :crash, do: nudge(vt, pty, st.cell_px)
      :ok
    end
  rescue
    e in [ArgumentError, ErlangError] -> {:error, {:raise, Exception.message(e)}}
  end

  defp restore_vt(id, %{vt: snap} = st) do
    with true <- is_binary(snap), {:ok, vt} <- Vt.restore(snap, st.max_scrollback) do
      vt
    else
      err ->
        Logger.warning(
          "handoff: pane #{id} screen lost (#{inspect(err, limit: 5)}); empty terminal"
        )

        {:ok, vt} = Vt.new(st.cols, st.rows, st.max_scrollback)
        vt
    end
  end

  # Crash path (ruling 11): full-screen apps repaint over a possibly stale snapshot.
  defp nudge(vt, pty, cell_px) do
    {cols, rows} = Vt.size(vt)

    if rows > 1 and Vt.mode(vt, :alt_screen) in [true, {:stale, true}] do
      Pty.resize(pty, cols, rows - 1, cell_px)
      Pty.resize(pty, cols, rows, cell_px)
    end
  end

  defp start(id, spec) do
    with {:ok, vt} <- Vt.new(spec.cols, spec.rows, spec.max_scrollback),
         {:ok, pty, os_pid} <-
           Pty.spawn(vt, id, spec.cmd, spec.args, spec.env, spec.cwd, spec.cols, spec.rows) do
      :ets.insert(
        @table,
        {id, %{vt: vt, pty: pty, os_pid: os_pid, max_scrollback: spec.max_scrollback}}
      )

      if spec.subscriber, do: Pty.subscribe(pty, spec.subscriber)
      :ok
    end
  rescue
    # Narrow on purpose: NIF badargs (ArgumentError) and ghostty raises (ErlangError)
    # become errors; anything else is a Keeper bug and should crash. The dropped pty
    # handle SIGHUPs its child.
    e in [ArgumentError, ErlangError] ->
      :ets.delete(@table, id)
      {:error, {:raise, Exception.message(e)}}
  end

  defp check(spec) when is_map(spec) do
    case Enum.find(@keys, &(not (is_map_key(spec, &1) and valid?(&1, spec[&1])))) do
      nil -> :ok
      key -> {:error, {:invalid_spec, key}}
    end
  end

  defp check(_spec), do: {:error, {:invalid_spec, :spec}}

  defp valid?(:cmd, v), do: is_binary(v)
  defp valid?(:args, v), do: list_of?(v, &is_binary/1)
  defp valid?(:env, v), do: list_of?(v, &match?({k, x} when is_binary(k) and is_binary(x), &1))
  defp valid?(:cwd, v), do: is_binary(v) or is_nil(v)
  defp valid?(:max_scrollback, v), do: is_integer(v) and v >= 0
  defp valid?(:subscriber, v), do: is_pid(v) or is_nil(v)
  defp valid?(_size, v), do: Vt.is_size(v)

  defp list_of?(v, ok?), do: is_list(v) and not List.improper?(v) and Enum.all?(v, ok?)
end
