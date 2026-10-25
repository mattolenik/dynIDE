defmodule HerdrServer.Native.Keeper do
  @moduledoc """
  Owns every kernel resource (vt and pty) and the pane-id table. Everything
  else refers to panes by id and reads the table from ETS (`lookup/1`).

  A bad spec or a raising NIF returns an error instead of crashing the Keeper:
  a crash would lose the table and SIGHUP every pane.

  From `prepare/0` until `thaw/0` the Keeper is frozen: `open/1` and `close/1` return
  `{:error, :handoff}` and change nothing (the broker's entries already describe the
  final state).

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
  # pending: id => {input taken by `prepare/0`, the final state sent with it}, written
  #   back by `thaw/0`.
  # carried: id => input an adopted pane brought along, written by `write_carried/0`.
  # frozen: between `prepare/0` and `thaw/0`.
  defstruct next_id: 1, closing: %{}, pending: %{}, carried: %{}, frozen: false

  @type id :: pos_integer
  @typedoc "`max_scrollback` is in bytes (e.g. 10_000_000); cols and rows are in 1..65535."
  @type spec :: %{
          optional(:replay) => binary | nil,
          cmd: binary,
          args: [binary],
          env: [{binary, binary | nil}],
          cwd: binary | nil,
          cols: pos_integer,
          rows: pos_integer,
          max_scrollback: non_neg_integer,
          subscriber: pid | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Creates the vt and pty for `spec` and returns the new pane id. An optional
  `replay` binary is fed to the new vt before the child starts (restored history).
  `{:error, {:invalid_spec, key}}` for a missing or ill-typed key,
  `{:error, Pty.spawn_error()}` when the spawn fails, `{:error, {:raise, message}}`
  when a NIF raises (a pane already started is closed again), `{:error, :handoff}`
  while frozen.
  """
  @spec open(spec) :: {:ok, id} | {:error, term}
  def open(spec) do
    with :ok <- check(spec), do: GenServer.call(__MODULE__, {:open, spec})
  end

  @spec lookup(id) ::
          {:ok,
           %{
             vt: Vt.vt(),
             pty: Pty.pty(),
             os_pid: pos_integer,
             max_scrollback: non_neg_integer,
             cmd: [binary] | nil
           }}
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
  `{:error, :handoff}` while frozen.
  """
  @spec close(id) :: :ok | {:error, :handoff}
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

  @doc """
  New VM, called by `Handoff.Link` right after RESTORED: writes the input adopted panes
  carried over. Before RESTORED the broker holds blobs with that input cleared (staged
  by `init`), so the bytes reach the child at most once whatever fails.
  """
  @spec write_carried() :: :ok
  def write_carried, do: GenServer.call(__MODULE__, :write_carried, :infinity)

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
    if state.frozen, do: {:reply, {:error, :handoff}, state}, else: open_pane(spec, state)
  end

  def handle_call({:close, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    cond do
      state.frozen ->
        {:reply, {:error, :handoff}, state}

      match?({:ok, _}, lookup(id)) ->
        Link.drop(key(id))
        {:reply, :ok, retire(id, state)}

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:adopt, entries, reason}, _from, state) do
    {:reply, :ok, adopt(entries, reason, Map.merge(%__MODULE__{}, state))}
  end

  def handle_call(:write_carried, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    for {id, bytes} <- state.carried,
        {:ok, row} <- [lookup(id)],
        do: write_pending(id, row.pty, bytes)

    {:reply, :ok, %{state | carried: %{}}}
  end

  def handle_call(:prepare, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    :ok = Snapshotter.pause()

    pending =
      Map.new(rows(), fn {id, row} ->
        Pty.freeze(row.pty)
        pending = Pty.take_pending(row.pty)
        {id, {pending, final_update(id, row, pending)}}
      end)

    {:reply, :ok, %{state | pending: pending, frozen: true}}
  end

  def handle_call(:thaw, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    for {id, row} <- rows() do
      case Map.get(state.pending, id) do
        {bytes, st} when bytes != "" ->
          # The broker's blob still carries `bytes`: clear it before they reach the
          # child, or a crash after this thaw would replay them in the next VM.
          Link.update(key(id), State.encode(%{st | pending_input: ""}))
          thaw_pty(id, row.pty)
          write_pending(id, row.pty, bytes)

        _ ->
          thaw_pty(id, row.pty)
      end
    end

    :ok = Snapshotter.resume()
    {:reply, :ok, %{state | pending: %{}, frozen: false}}
  end

  def handle_call(:release, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    for {id, row} <- rows(),
        {:error, reason} <- [Pty.release(row.pty)],
        do: Logger.warning("handoff: release of pane #{id} failed: #{inspect(reason)}")

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

  defp open_pane(spec, state) do
    id = state.next_id

    with :ok <- check(spec), :ok <- start(id, spec), :ok <- hold(id) do
      {:reply, {:ok, id}, %{state | next_id: id + 1}}
    else
      # started, but the broker never got it: close it again (the id stays used)
      {:error, {:hold, msg}} ->
        {:reply, {:error, {:raise, msg}}, retire(id, %{state | next_id: id + 1})}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # Before `open` replies (ruling 3): a kill -9 after open returns cannot lose the pane.
  defp hold(id) do
    with true <- Link.enabled?(),
         {:ok, row} <- lookup(id),
         do: Link.hold(key(id), State.encode(State.build(id, row, vt: false)), [row.pty])

    :ok
  rescue
    # same narrow rescue as `start/2`: a raising NIF must not take the table down
    e in [ArgumentError, ErlangError] -> {:error, {:hold, Exception.message(e)}}
  end

  # SIGHUP now, SIGKILL after @escalate_ms; the row leaves the table.
  defp retire(id, state) do
    case lookup(id) do
      {:ok, %{pty: pty}} ->
        Pty.kill(pty, :hup)
        :ets.delete(@table, id)
        Process.send_after(self(), {:escalate, id}, @escalate_ms)
        %{state | closing: Map.put(state.closing, id, pty)}

      :error ->
        state
    end
  end

  defp thaw_pty(id, pty) do
    with {:error, reason} <- Pty.thaw(pty),
         do: Logger.warning("handoff: thaw of pane #{id} failed: #{inspect(reason)}")
  end

  # Sends and returns the final state of pane `id`.
  defp final_update(id, row, pending) do
    st = State.build(id, row, pending_input: pending, gfx: true)
    Link.update(key(id), State.encode(st))
    st
  rescue
    # ghostty refused the snapshot: the screen is lost, the input must not be
    e in ErlangError ->
      Logger.warning("handoff: final screen of pane #{id} lost: #{Exception.message(e)}")
      st = State.build(id, row, vt: false, pending_input: pending)
      Link.update(key(id), State.encode(st))
      st
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
        carry(id, st, %{state | next_id: max(state.next_id, id + 1)})
      else
        err ->
          Logger.warning("handoff: pane #{key} not adopted: #{inspect(err, limit: 5)}")
          Link.unclaim(key)
          state
      end
    end)
  end

  defp adopt_one(id, st, fd, reason) do
    {vt, restored?} = restore_vt(id, st)
    # before Pty.adopt: no reader yet, and q=2 replies nothing to the child; never onto
    # the empty fallback screen
    with true <- restored?,
         gfx when is_binary(gfx) and gfx != "" <- Map.get(st, :gfx),
         do: Vt.feed(vt, gfx)

    exited = st.exited != nil
    start = Map.get(st, :start_time)

    with {:ok, pty} <- Pty.adopt(vt, id, fd, st.os_pid, exited, st.title, st.pwd, start) do
      row = %{
        vt: vt,
        pty: pty,
        os_pid: st.os_pid,
        max_scrollback: st.max_scrollback,
        cmd: carried_cmd(Map.get(st, :cmd))
      }

      :ets.insert(@table, {id, row})

      if st.hidden, do: Pty.set_hidden(pty, true)
      if reason == :crash and st.exited == nil, do: nudge(vt, pty, st.cell_px)
      :ok
    end
  rescue
    e in [ArgumentError, ErlangError] -> {:error, {:raise, Exception.message(e)}}
  end

  # metadata from the blob: only a list of binaries survives, anything else is nil
  defp carried_cmd(cmd) do
    if is_list(cmd) and not List.improper?(cmd) and Enum.all?(cmd, &is_binary/1), do: cmd
  end

  defp carry(_id, %{pending_input: ""}, state), do: state

  defp carry(id, st, state) do
    # staged by the broker, applied atomically with our RESTORED
    Link.update(key(id), State.encode(%{st | pending_input: ""}))
    %{state | carried: Map.put(state.carried, id, st.pending_input)}
  end

  defp restore_vt(id, %{vt: snap} = st) do
    with true <- is_binary(snap), {:ok, vt} <- Vt.restore(snap, st.max_scrollback) do
      {vt, true}
    else
      err ->
        Logger.warning(
          "handoff: pane #{id} screen lost (#{inspect(err, limit: 5)}); empty terminal"
        )

        {:ok, vt} = Vt.new(st.cols, st.rows, st.max_scrollback)
        {vt, false}
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
         :ok <- replay(vt, spec),
         {:ok, pty, os_pid} <-
           Pty.spawn(vt, id, spec.cmd, spec.args, spec.env, spec.cwd, spec.cols, spec.rows) do
      row = %{
        vt: vt,
        pty: pty,
        os_pid: os_pid,
        max_scrollback: spec.max_scrollback,
        cmd: [spec.cmd | spec.args]
      }

      :ets.insert(@table, {id, row})

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

  defp replay(vt, %{replay: bytes}) when is_binary(bytes) and bytes != "" do
    Vt.feed(vt, bytes)
    :ok
  end

  defp replay(_vt, _spec), do: :ok

  defp check(spec) when is_map(spec) do
    cond do
      key = Enum.find(@keys, &(not (is_map_key(spec, &1) and valid?(&1, spec[&1])))) ->
        {:error, {:invalid_spec, key}}

      not (is_binary(Map.get(spec, :replay)) or is_nil(Map.get(spec, :replay))) ->
        {:error, {:invalid_spec, :replay}}

      true ->
        :ok
    end
  end

  defp check(_spec), do: {:error, {:invalid_spec, :spec}}

  defp valid?(:cmd, v), do: is_binary(v)
  defp valid?(:args, v), do: list_of?(v, &is_binary/1)

  defp valid?(:env, v),
    do: list_of?(v, &match?({k, x} when is_binary(k) and (is_binary(x) or is_nil(x)), &1))

  defp valid?(:cwd, v), do: is_binary(v) or is_nil(v)
  defp valid?(:max_scrollback, v), do: is_integer(v) and v >= 0
  defp valid?(:subscriber, v), do: is_pid(v) or is_nil(v)
  defp valid?(_size, v), do: Vt.is_size(v)

  defp list_of?(v, ok?), do: is_list(v) and not List.improper?(v) and Enum.all?(v, ok?)
end
