defmodule HerdrServer.Handoff.Link do
  @moduledoc """
  This VM's connection to `herdr_broker` (rulings 3, 7, 9 and the wire protocol in
  `docs/herdr-live/plans/m5.md`). Without `HERDR_BROKER_SOCK` (mix test, iex) `init`
  is `:ignore` and every call below is a cheap no-op.

  With it, `init` sends HELLO and blocks application start until the broker answers
  FRESH or ADOPT* + ADOPT_END, so later children (the Keeper, `App.Store`) can claim
  adopted entries with `take_adopted/1`. HOLD/UPDATE/DROP go straight from the caller
  through the link resource in `:persistent_term`, never through this process, so
  `Keeper.open` cannot be delayed by a slow request here.

  The current handoff phase (`:begin`, `:aborted`, `:released`) is kept under
  `HerdrScene.Protocol.handoff_key/0` for the local terminal client, which cannot
  subscribe to `Handoff.Notice`. On PREPARE the Link waits (at most 2 s) for the local
  client (`Protocol.local_client_name/0`) to stop, so its tty restore is done before the
  next VM's client can open the tty, and flushes `App.Store`'s pending HOLD. After the
  freeze it stops `HerdrServer.Control` (removing its socket) so the next VM can serve
  `herdr-live rollback`; THAW restarts it.

  ctl REQUESTs are queued until `restored/0` has run (Application.start calls it once the
  supervisor is up, after FRESH as after an adoption), then run in order: a request the
  broker forwards right after FRESH must not reach a Keeper whose `App.Store.init` is
  still to close every pane.

  PREPARE is a barrier for ctl requests: requests already running finish first (at most
  2 s, then a warning), so none races the Keeper freeze; requests that arrive
  later wait for THAW, and after RELEASE they never run in this VM (the broker queues
  them for the next one anyway).

  A closed link while primary halts the VM: the broker already treats it as dead and
  adopts its panes elsewhere.
  """
  use GenServer

  require Logger

  alias HerdrScene.Protocol
  alias HerdrServer.App.Store
  alias HerdrServer.Handoff.{Ctl, Notice}
  alias HerdrServer.Native.{Keeper, Pty}
  alias HerdrServer.Native.Link, as: NLink

  @key {__MODULE__, :link}
  @local_client_ms 2000
  @ctl_drain_ms 2000

  defstruct link: nil,
            gen: 0,
            reason: nil,
            adopted: [],
            claimed: 0,
            rejected: [],
            released: false,
            ctl: :queue.new(),
            ready: false,
            worker: nil,
            # PREPARE..THAW: requests wait in `later`
            frozen: false,
            later: :queue.new()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec enabled?() :: boolean
  def enabled?, do: link() != nil

  @doc "Hands `fds` (dups are sent) and `blob` to the broker under `key`."
  # fds: `Pty.pty()` or `Pty.fd()` (a plain list: the opaque pty in a union trips dialyzer)
  @spec hold(binary, binary, list) :: :ok
  def hold(key, blob, fds), do: send_frame(:hold, NLink.frame_key(key, blob), fds)

  @spec update(binary, binary) :: :ok
  def update(key, blob), do: send_frame(:update, NLink.frame_key(key, blob), [])

  @spec drop(binary) :: :ok
  def drop(key), do: send_frame(:drop, NLink.frame_key(key, ""), [])

  @doc "Claims the adopted entries whose key starts with `prefix`."
  @spec take_adopted(binary) :: [{binary, binary, [Pty.fd()]}]
  def take_adopted(prefix), do: call({:take, prefix}, [])

  @doc "Gives back a claimed entry that could not be used: `restored/0` drops it."
  @spec unclaim(binary) :: :ok
  def unclaim(key), do: call({:unclaim, key}, :ok)

  @spec adopt_reason() :: :graceful | :crash | nil
  def adopt_reason, do: call(:reason, nil)

  @doc "After an adoption: RESTORED to the broker, DROPs for unclaimed entries."
  @spec restored() :: :ok
  def restored, do: call(:restored, :ok)

  @doc false
  # Test hook: runs a Link without a broker whose adopted list is `entries`.
  @spec put_adopted_for_test([{binary, binary, [Pty.fd()]}]) :: :ok
  def put_adopted_for_test(entries) do
    {:ok, _} = GenServer.start(__MODULE__, {:adopted_for_test, entries}, name: __MODULE__)
    :ok
  end

  defp call(msg, disabled) do
    if GenServer.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, msg, :infinity),
      else: disabled
  end

  defp link, do: :persistent_term.get(@key, nil)

  defp send_frame(kind, body, fds) do
    with l when l != nil <- link(),
         {:error, reason} <- NLink.send(l, NLink.kind(kind), body, fds) do
      # the link is closed now; this process halts the VM on the close message
      Logger.error("handoff link: #{kind} failed: #{inspect(reason)}")
    end

    :ok
  end

  @impl true
  def init({:adopted_for_test, entries}),
    do: {:ok, %__MODULE__{reason: :graceful, adopted: entries}}

  def init(_opts) do
    case System.get_env("HERDR_BROKER_SOCK") do
      nil -> :ignore
      path -> connect(path)
    end
  end

  defp connect(path) do
    # A restart after a crash: our old link closed with its owner, so the broker
    # has already handed our panes to another VM.
    if link(), do: halt("handoff link restarted")
    gen = "HERDR_LIVE_GEN" |> System.get_env("0") |> String.to_integer()
    os_pid = String.to_integer(System.pid())
    {us, n} = :timer.tc(&preload/0)
    {up, _} = :erlang.statistics(:wall_clock)

    Logger.info(
      "handoff link gen=#{gen} preloaded #{n} modules in #{div(us, 1000)} ms (vm up #{up} ms)"
    )

    with {:ok, l} <- NLink.connect(path, self()),
         :ok <- NLink.send(l, NLink.kind(:hello), <<gen::64, os_pid::32>>, []) do
      {reason, adopted} = await(l, [])
      :persistent_term.put(@key, l)
      Logger.info("handoff link gen=#{gen} #{reason || :fresh} entries=#{length(adopted)}")
      {:ok, %__MODULE__{link: l, gen: gen, reason: reason, adopted: adopted}}
    else
      {:error, reason} -> {:stop, {:broker_link, reason}}
    end
  end

  @doc false
  # Adopted blobs decode with `[:safe]`, which rejects atoms the VM has not seen yet
  # (struct fields of a module not loaded so far): load every umbrella module before
  # HELLO, which also warms a standby before it is promoted. Returns the module count.
  @spec preload() :: non_neg_integer
  def preload do
    mods =
      for app <- [:herdr_scene, :herdr_server, :herdr_term],
          _ = Application.load(app),
          m <- Application.spec(app, :modules) || [],
          do: m

    Enum.each(mods, &Code.ensure_loaded/1)
    length(mods)
  end

  @fresh NLink.kind(:fresh)
  @adopt NLink.kind(:adopt)
  @adopt_end NLink.kind(:adopt_end)

  # Plain receive on purpose: a standby VM waits here until it is promoted.
  defp await(l, acc) do
    receive do
      {:herdr_link, ^l, @fresh, _, _} ->
        {nil, []}

      {:herdr_link, ^l, @adopt, body, fds} ->
        {key, blob} = NLink.parse_key(body)
        await(l, [{key, blob, fds} | acc])

      {:herdr_link, ^l, @adopt_end, <<_count::32, r>>, _} ->
        {if(r == 0, do: :graceful, else: :crash), Enum.reverse(acc)}

      {:herdr_link_closed, ^l, reason} ->
        halt("handoff link closed before start: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_call({:take, prefix}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    {mine, rest} =
      Enum.split_with(state.adopted, fn {k, _, _} -> String.starts_with?(k, prefix) end)

    {:reply, mine, %{state | adopted: rest, claimed: state.claimed + length(mine)}}
  end

  def handle_call({:unclaim, key}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | rejected: [key | state.rejected], claimed: state.claimed - 1}}
  end

  def handle_call(:reason, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.reason, state}
  end

  def handle_call(:restored, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    :persistent_term.erase(Protocol.handoff_key())

    if state.reason == nil do
      {:reply, :ok, run_queued(state)}
    else
      # staged by the broker with the Keeper's UPDATEs, applied at RESTORED
      for {k, _, _} <- state.adopted, do: drop(k)
      for k <- state.rejected, do: drop(k)
      :ok = send_frame(:restored, <<state.claimed::32>>, [])
      # after RESTORED (at most once) and before any queued ctl request runs
      :ok = Keeper.write_carried()
      notice(:adopted, state)
      {:reply, :ok, run_queued(%{state | adopted: [], rejected: []})}
    end
  end

  @request NLink.kind(:request)
  @prepare NLink.kind(:prepare)
  @thaw NLink.kind(:thaw)
  @release NLink.kind(:release)

  @impl true
  def handle_info({:herdr_link, _, @request, <<ref::64, payload::binary>>, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, enqueue(state, {ref, payload})}
  end

  def handle_info({:ctl_done, ref}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {{:value, {^ref, _}}, ctl} = :queue.out(state.ctl)
    {:noreply, %{state | ctl: ctl}}
  end

  def handle_info({:DOWN, mref, :process, _, reason} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)

    case state.worker do
      {_, ^mref} -> {:noreply, worker_down(reason, state)}
      _ -> unexpected(msg, state)
    end
  end

  def handle_info({:herdr_link, _, @prepare, _, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    :persistent_term.put(Protocol.handoff_key(), :begin)
    # notice first, so clients stop writing before the panes freeze
    notice(:begin, state)
    await_local_client()
    :ok = Store.flush_hold()
    state = drain_ctl(%{state | frozen: true})
    :ok = Keeper.prepare()
    # the next VM serves `herdr-live rollback`: free the socket path for it
    _ = Supervisor.terminate_child(HerdrServer.Supervisor, HerdrServer.Control)
    send_frame(:prepared, "", [])
    {:noreply, state}
  end

  def handle_info({:herdr_link, _, @thaw, _, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    :ok = Keeper.thaw()
    _ = Supervisor.restart_child(HerdrServer.Supervisor, HerdrServer.Control)
    :persistent_term.put(Protocol.handoff_key(), :aborted)
    notice(:aborted, state)
    later = :queue.to_list(state.later)

    {:noreply,
     Enum.reduce(later, %{state | frozen: false, later: :queue.new()}, &enqueue(&2, &1))}
  end

  def handle_info({:herdr_link, _, @release, _, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    :persistent_term.put(Protocol.handoff_key(), :released)
    notice(:released, state)
    :ok = Keeper.release()
    Logger.info("handoff: released, stopping")
    System.stop(0)
    {:noreply, %{state | released: true}}
  end

  def handle_info({:herdr_link_closed, _, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if not state.released, do: halt("handoff link closed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(msg, state), do: unexpected(msg, Map.merge(%__MODULE__{}, state))

  defp unexpected(msg, state) do
    Logger.warning("handoff link: unexpected #{inspect(msg, limit: 5)}")
    {:noreply, state}
  end

  # ctl requests run FIFO in one worker: a slow one never holds up PREPARE, pipelined
  # writes keep their order, and the broker gets exactly one REPLY per ref.
  defp worker_down(reason, state) do
    # the head of the queue was in flight: answer it, rerun the rest in order
    ctl =
      case :queue.out(state.ctl) do
        {{:value, {ref, _}}, rest} ->
          reply(ref, {:error, {:crashed, reason}})
          rest

        {:empty, rest} ->
          rest
      end

    state = ensure_worker(%{state | worker: nil, ctl: ctl})

    for {ref, payload} <- :queue.to_list(ctl),
        do: send(elem(state.worker, 0), {:req, ref, payload})

    state
  end

  defp enqueue(%{frozen: true} = state, req), do: %{state | later: :queue.in(req, state.later)}

  defp enqueue(state, {ref, payload} = req) do
    state = %{state | ctl: :queue.in(req, state.ctl)}

    if state.ready do
      state = ensure_worker(state)
      send(elem(state.worker, 0), {:req, ref, payload})
      state
    else
      state
    end
  end

  # PREPARE: lets the requests the worker already has finish (selective receive; new
  # REQUESTs stay in the mailbox and go to `later` afterwards).
  defp drain_ctl(state),
    do: drain_ctl(state, System.monotonic_time(:millisecond) + @ctl_drain_ms)

  defp drain_ctl(%{ready: true, worker: {_, mref}} = state, deadline) do
    if :queue.is_empty(state.ctl) do
      state
    else
      receive do
        {:ctl_done, ref} ->
          {{:value, {^ref, _}}, ctl} = :queue.out(state.ctl)
          drain_ctl(%{state | ctl: ctl}, deadline)

        {:DOWN, ^mref, :process, _, reason} ->
          drain_ctl(worker_down(reason, state), deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          Logger.warning(
            "handoff: #{:queue.len(state.ctl)} ctl requests still running after #{@ctl_drain_ms} ms"
          )

          state
      end
    end
  end

  # not running requests yet (before restored/0): nothing in flight
  defp drain_ctl(state, _deadline), do: state

  # restored/0 ran: from now on requests go straight to the worker
  defp run_queued(%{ready: true} = state), do: state

  defp run_queued(state) do
    state = ensure_worker(%{state | ready: true})

    for {ref, payload} <- :queue.to_list(state.ctl),
        do: send(elem(state.worker, 0), {:req, ref, payload})

    state
  end

  defp ensure_worker(%{worker: nil} = state) do
    link = self()
    handler = Application.get_env(:herdr_server, HerdrServer.Handoff, [])[:ctl] || Ctl
    pid = spawn(fn -> worker(Process.monitor(link), link, handler) end)
    %{state | worker: {pid, Process.monitor(pid)}}
  end

  defp ensure_worker(state), do: state

  defp worker(mref, link, handler) do
    receive do
      {:req, ref, payload} ->
        reply(ref, handler.handle(decode(payload)))
        send(link, {:ctl_done, ref})
        worker(mref, link, handler)

      {:DOWN, ^mref, _, _, _} ->
        :ok
    end
  end

  defp reply(ref, term), do: send_frame(:reply, [<<ref::64>>, :erlang.term_to_binary(term)], [])

  defp decode(payload) do
    :erlang.binary_to_term(payload, [:safe])
  rescue
    ArgumentError -> {:bad_request, byte_size(payload)}
  end

  # the local client stops on the :begin notice and restores the tty in its terminate,
  # before its :DOWN: only then may the next VM's client open the tty
  defp await_local_client do
    with pid when is_pid(pid) <- Process.whereis(Protocol.local_client_name()) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        @local_client_ms ->
          Process.demonitor(ref, [:flush])
          Logger.warning("handoff: local client still running after #{@local_client_ms} ms")
      end
    end
  end

  defp notice(phase, state),
    do: Notice.broadcast({:handoff, %{phase: phase, gen: state.gen, panes: Keeper.ids()}})

  @spec halt(binary) :: no_return
  defp halt(why) do
    Logger.error(why <> "; halting")
    :logger_std_h.filesync(:default)
    System.halt(1)
  end
end
