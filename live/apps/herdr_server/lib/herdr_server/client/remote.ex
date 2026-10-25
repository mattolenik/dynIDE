defmodule HerdrServer.Client.Remote do
  @moduledoc """
  One per socket client (`restart: :temporary`), registered under its `client_id` in
  `HerdrServer.Client.Remote.Registry`. It is the client pid its `Client.Session` talks
  to (attached through `Protocol.endpoint()` with `transport: :inline`), and it speaks
  `HerdrScene.Wire` on the socket that `Client.Socket` hands it with `resume/4`.

  Output: scenes and rows go through `Client.Outbox` (coalesced, only changed rows) and
  are flushed when the last flush is `frame_ms` old and the previous frames have left
  the driver queue (`send_pend == 0`), so a slow reader coalesces instead of queueing. A
  reader that has not drained for `stuck_ms` (default 30 s) is dropped like a lost socket.
  Every other session message flushes what is pending first, then goes at once.

  Input (R8): a client frame is rejected with a warning notice unless it is plain data
  and valid; the connection stays. `{:input, w, ev}` is forwarded when `w > last_seq`,
  re-acked when `w <= acked`, dropped otherwise (in flight: its ack comes later), so a
  client resending unacked input after a reconnect applies it exactly once. A frame over
  the size limit, or one that does not decode, closes the socket.

  The callbacks here are thin: input and attach live here, output scheduling and the
  socket's lifetime in `Client.Remote.Out`, the handoff carry in `Client.Remote.Carry`.

  Grace (R9): when the socket goes, the conn (and its session) lingers `grace_ms`; a
  `resume/4` with the same `client_id` re-arms it: `{:attached, %{resumed: true}}`, a full
  scene, the input mode when not `:terminal`, and a resize when the size changed (an
  internal input with seq from 2^62, its ack swallowed). A resume while connected closes
  the old socket after `{:detached, :replaced}`. Expiry stops the conn normally, which
  ends the session. A session that ends sends `{:detached, reason}` (if it did not) and
  stops the conn.

  Handoff (R11): while it has a socket the conn HOLDs `client/<client_id>` in the broker
  (blob `%{v: 1, client_id, info, acked, buffer}`, fd a dup of the socket) and DROPs it
  before any server-side close (the broker's dup would keep the peer from seeing EOF).
  `prepare_all/0` freezes every conn: passive socket, received bytes into the buffer,
  queued output given 200 ms to leave the driver (else the socket is dropped, not
  carried), an UPDATE with `prepared: true`, then no reads and no writes (output is kept)
  until `thaw_all/0`, which UPDATEs `prepared: false` back. A conn that does not answer
  prepare in 1 s is DROPped (and HOLDs again at THAW). `terminate/2` DROPs too, so a crashed conn's peer sees EOF.
  A new VM's `Client.Socket` starts one adopted conn per entry. A prepared blob is
  carried: a new session with the blob's info, `last_seq := acked`,
  `{:attached, %{resumed: :handoff}}`, a full scene, then the carried buffer. Any other
  usable blob (a crash, an earlier aborted handoff: the stream may be mid-frame) starts
  the conn in grace without a socket; the entry is unclaimed and the fd closed, so the
  client sees EOF, reconnects and resumes (R9). A bad blob is unclaimed and its fd
  closed. The hold module is `config :herdr_server, :client_hold` (tests record).

  Pane mode (R17, target `{:pane, id, :observe | :control}`, `Client.Remote.Pane`): no `Client.Session`. The
  conn registers under `HerdrServer.Client.Registry` `:clients` (so `{:pane_damage, id, _}`
  reaches it) and follows the Store; each damage of its pane is a `Client.PaneScene`
  through the outbox. `:control` writes keys, mouse and paste to `Pane.Input`, `:observe`
  drops them; every input is acked (a resize only reshapes the scene). The pane leaving the
  app (or its rows) sends `{:detached, :pane_closed}`. No grace and no hold: a lost socket,
  a `{:detach}` or a handoff PREPARE stops the conn, and input during a handoff closes the
  socket unacked; the client reconnects (to the next VM) and resends it.
  """
  use GenServer, restart: :temporary

  require Logger

  alias HerdrReload.Guard
  alias HerdrScene.{Protocol, Wire}
  alias HerdrServer.App.Store
  alias HerdrServer.Client.{Outbox, Socket}
  alias HerdrServer.Client.Remote.{Carry, Out, Pane}
  alias HerdrServer.Persist.Schema

  @internal_seq 4_611_686_018_427_387_904
  @immediate [:notice, :alert, :handoff, :clipboard, :bell, :open_url, :damage]
  # a pane conn's socket must arrive within the handshake time
  @pane_wait_ms 5000

  defstruct id: nil,
            info: nil,
            socket: nil,
            buf: "",
            session: nil,
            session_ref: nil,
            outbox: %Outbox{},
            last_flush: 0,
            flush_timer: nil,
            last_seq: -1,
            acked: -1,
            internal: @internal_seq,
            grace_ref: nil,
            away_since: nil,
            detached: false,
            mode: :terminal,
            fresh: true,
            frame_ms: 8,
            grace_ms: 60_000,
            stuck_ms: 30_000,
            pend_since: nil,
            held: false,
            # an adopted socket's fd: its fdopen'd port never closes it
            fd: nil,
            # PREPARE..THAW: no reads, writes kept in frozen_out (newest first)
            frozen: false,
            frozen_out: [],
            # pane mode (R17): the pane id and the Store monitor
            pane: nil,
            store_ref: nil

  def start_link(info), do: GenServer.start_link(__MODULE__, info)

  @doc "Socket clients: id, kind, target, size and whether a socket is attached now."
  @spec list() :: [
          %{id: binary, kind: atom, target: term, size: map, connected: boolean}
        ]
  def list do
    __MODULE__.Registry
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {id, meta} -> Map.put(meta, :id, id) end)
  end

  @doc """
  Handoff PREPARE: freezes every conn (1 s each, in parallel). A conn that does not
  answer in time loses its entry (DROP, honoured before PREPARED): its client reconnects.
  """
  @spec prepare_all() :: :ok
  def prepare_all do
    pids = conns()
    results = each_conn(:prepare)
    late = for {id, :timeout} <- results, do: id

    for id <- late do
      Carry.hold_mod().drop("client/" <> id)
      # so its THAW holds it again (it reads this after the late :prepare)
      if pid = pids[id], do: send(pid, :hold_dropped)
    end

    HerdrReload.Telemetry.event(:client_handoff_freeze,
      conns: length(results),
      late: length(late)
    )
  end

  @doc "Handoff THAW: every conn reads and writes again."
  @spec thaw_all() :: :ok
  def thaw_all do
    _ = each_conn(:thaw)
    :ok
  end

  @doc "Whether a handoff is under way: no conn takes a new socket now."
  @spec handoff?() :: boolean
  def handoff?, do: :persistent_term.get(Protocol.handoff_key(), nil) in [:begin, :released]

  defp conns,
    do:
      Map.new(
        Registry.select(__MODULE__.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      )

  # [{client_id, :ok | :timeout}]
  defp each_conn(msg) do
    conns = conns()

    conns
    |> Task.async_stream(fn {id, pid} -> {id, call_conn(pid, msg)} end,
      timeout: :infinity,
      max_concurrency: max(map_size(conns), 1)
    )
    |> Enum.map(fn {:ok, r} -> r end)
  end

  defp call_conn(pid, msg) do
    GenServer.call(pid, msg, 1000)
  catch
    :exit, reason ->
      Logger.warning("client conn #{msg}: #{inspect(reason, limit: 5)}")
      :timeout
  end

  @doc false
  # by Client.Socket after giving `pid` the socket; `buf` is what followed the attach frame
  # `:handoff`: refused during a handoff, the socket is already closed
  # `:refused`: another target under this client_id, refused and closed
  @spec resume(pid, :gen_tcp.socket(), map, binary) :: :ok | :error | :handoff | :refused
  def resume(pid, socket, info, buf) do
    # the conn may be closing a stuck old socket first: never time out (and retry) here
    GenServer.call(pid, {:resume, socket, info, buf}, :infinity)
  catch
    :exit, _ -> :error
  end

  @impl true
  def init({:adopted, {key, blob, fds}}) do
    with {:ok, b} <- Carry.decode(blob),
         {:ok, s, fd} <- Carry.carried(b, fds) do
      adopt(key, b, s, fd)
    else
      # not frozen for this handoff (a crash, an earlier aborted one) or not usable: the
      # session waits in grace for the client, which sees EOF and resumes it (R9)
      {:grace, b} ->
        Carry.held_event(b.client_id, false)

        # registered before the client can see EOF, so its reconnect resumes this conn
        result =
          try do
            init(b.info)
          after
            Carry.not_carried(key, nil, fds)
          end

        case result do
          # a resume, not a first attach: the client resends what is not acked
          {:ok, state} ->
            {:ok, %{state | fresh: false, last_seq: b.acked, acked: b.acked}}

          _ ->
            :ignore
        end

      :error ->
        Carry.held_event(String.replace_prefix(key, "client/", ""), false)
        Carry.not_carried(key, nil, fds)
    end
  end

  def init(info) do
    case Registry.register(__MODULE__.Registry, info.client_id, meta(info, false)) do
      {:ok, _} -> if match?({:pane, _, _}, info.target), do: pane_attach(info), else: attach(info)
      # raced another connection to this id: Client.Socket resumes that one
      {:error, {:already_registered, _}} -> :ignore
    end
  end

  defp attach(info) do
    req = %{
      kind: info.kind,
      transport: :inline,
      size: info.size,
      cell_px: info.cell_px,
      caps: info.caps,
      client: self()
    }

    case GenServer.call(Protocol.endpoint(), {:attach, req}) do
      {:ok, session, _} ->
        attach_event(info)
        # so terminate/2 DROPs the hold on a supervisor shutdown too
        Process.flag(:trap_exit, true)
        state = %{configured(info) | session: session, session_ref: Process.monitor(session)}
        # the socket comes with resume/4; a conn that never gets one ends like a drop
        {:ok, Out.away(state)}

      {:error, why} ->
        {:stop, {:attach, why}}
    end
  end

  # Client.Socket checked the pane; one closed since is :ignore (the handshake retries)
  defp pane_attach(%{target: {:pane, id, _}} = info) do
    case Pane.attach(id, info.size) do
      :ignore ->
        :ignore

      {:ok, scene, store_ref} ->
        attach_event(info)
        # no grace: once it had a socket, a drop stops the conn at once
        state = %{configured(info) | pane: id, store_ref: store_ref, grace_ms: 0}
        # the socket comes with resume/4 within the handshake time
        {:ok, Out.arm(Out.put(state, scene), @pane_wait_ms)}
    end
  end

  defp configured(info) do
    cfg = Application.get_env(:herdr_server, :client_socket, [])

    %__MODULE__{
      id: info.client_id,
      info: info,
      frame_ms: Keyword.get(cfg, :frame_ms, 8),
      grace_ms: Keyword.get(cfg, :grace_ms, 60_000),
      stuck_ms: Keyword.get(cfg, :stuck_ms, 30_000)
    }
  end

  defp attach_event(info),
    do:
      HerdrReload.Telemetry.event(:client_attach,
        id: short(info.client_id),
        kind: info.kind,
        target: info.target,
        cols: info.size.cols,
        rows: info.size.rows
      )

  @impl true
  def handle_call({:resume, s, info, buf}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    if state.frozen or handoff?() do
      # a handshake that raced the freeze: the client reconnects to the next VM
      :gen_tcp.close(s)
      {:reply, :handoff, state}
    else
      resume_target(state, s, info, buf)
    end
  end

  # not carried: the client reconnects to the next VM
  def handle_call(:prepare, _from, %{pane: id} = state) when id != nil,
    do: {:reply, :ok, Out.drop(Map.merge(%__MODULE__{}, state))}

  def handle_call(:prepare, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, Carry.freeze(state)}
  end

  def handle_call(:thaw, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    held = Enum.reverse(state.frozen_out)
    # no longer prepared: a later crash must not carry this socket mid-stream
    state = Carry.update_hold(%{state | frozen: false, frozen_out: []})
    # dropped for a late prepare: carried again from now on
    state = if state.held, do: state, else: Carry.hold(state)
    state = Out.write_all(state, held)
    # what arrived before the freeze is still in the buffer
    state = if state.socket, do: received(state, ""), else: state
    {:reply, :ok, Out.schedule(state)}
  end

  # a client_id names one conn: a resume for another target is refused (m4)
  defp resume_target(state, s, %{target: t}, _buf) when t != state.info.target do
    HerdrReload.Telemetry.event(:client_refused, reason: "target mismatch")
    _ = :gen_tcp.send(s, Wire.encode({:refused, "target mismatch"}))
    :gen_tcp.close(s)
    {:reply, :refused, state}
  end

  defp resume_target(state, s, info, buf) do
    state = state |> connect(s, info, not state.fresh) |> Carry.hold()
    {:reply, :ok, received(state, buf)}
  end

  defp adopt(key, b, s, fd) do
    case init(b.info) do
      {:ok, state} ->
        # the broker still holds this socket under `key`; the old buffer is ours now
        state = %{state | last_seq: b.acked, acked: b.acked, held: true, fd: fd}
        state = state |> connect(s, b.info, :handoff) |> Carry.update_hold()
        Carry.held_event(b.client_id, true)
        {:ok, received(state, b.buffer)}

      _ ->
        Carry.held_event(b.client_id, false)
        Carry.not_carried(key, s, [fd])
    end
  catch
    # not a guard boundary: clean the entry up, then fail the start as before
    kind, reason ->
      Carry.held_event(b.client_id, false)
      Carry.not_carried(key, s, [fd])
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp connect(state, s, info, resumed) do
    state = if state.socket, do: Out.replaced(state), else: state

    unless state.fresh,
      do:
        HerdrReload.Telemetry.event(:client_reconnect,
          id: short(state.id),
          away_ms: Out.now() - (state.away_since || Out.now())
        )

    state = resized(state, info)
    Registry.update_value(__MODULE__.Registry, state.id, fn _ -> meta(info, true) end)

    state = %{
      state
      | socket: s,
        buf: "",
        grace_ref: nil,
        away_since: nil,
        pend_since: nil,
        fresh: false
    }

    state = Out.write(state, {:attached, %{resumed: resumed, session: Socket.session_name()}})
    state = Out.full(state)
    if state.mode != :terminal, do: Out.write(state, {:input_mode, state.mode}), else: state
  end

  @impl true
  def handle_info({:tcp, s, data}, %{socket: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, received(state, data)}
  end

  def handle_info({:tcp_closed, s}, %{socket: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.drop(state)}
  end

  def handle_info({:tcp_error, s, _}, %{socket: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.drop(state)}
  end

  def handle_info({:scene, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.schedule(Out.put(state, msg))}
  end

  def handle_info({:pane_damage, id, _}, %{pane: id} = state) when id != nil do
    state = Map.merge(%__MODULE__{}, state)

    case pane_scene(state) do
      {:ok, nil} -> pane_closed(state)
      {:ok, scene} -> {:noreply, Out.schedule(Out.put(state, scene))}
      {:failed, f} -> {:noreply, Out.failed(state, f)}
    end
  end

  def handle_info({:app_changed, app}, %{pane: id} = state) when id != nil do
    state = Map.merge(%__MODULE__{}, state)
    if Pane.open?(app, id), do: {:noreply, state}, else: pane_closed(state)
  end

  # the Store restarted from the mirror: follow the new one
  def handle_info({:DOWN, ref, :process, _, _}, %{store_ref: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)

    case Pane.follow_store(state.pane) do
      {:ok, ref} -> {:noreply, %{state | store_ref: ref}}
      :error -> pane_closed(state)
    end
  end

  def handle_info({:rows, _, _, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.schedule(Out.put(state, msg))}
  end

  # our own resizes
  def handle_info({:ack, w}, state) when w >= @internal_seq,
    do: {:noreply, Map.merge(%__MODULE__{}, state)}

  def handle_info({:ack, w} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.out(%{state | acked: max(state.acked, w)}, msg)}
  end

  def handle_info({:input_mode, m} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.out(%{state | mode: m}, msg)}
  end

  def handle_info({:detached, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.out(%{state | detached: true}, msg)}
  end

  def handle_info(msg, state) when is_tuple(msg) and elem(msg, 0) in @immediate do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.out(state, msg)}
  end

  def handle_info(:hold_dropped, state),
    do: {:noreply, %{Map.merge(%__MODULE__{}, state) | held: false}}

  def handle_info(:flush, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Out.schedule(%{state | flush_timer: nil})}
  end

  def handle_info({:grace, ref}, %{grace_ref: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    reason = if state.pane, do: :closed, else: :grace_expired
    HerdrReload.Telemetry.event(:client_detach, id: short(state.id), reason: reason)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{session_ref: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    state = if state.detached, do: state, else: Out.out(state, {:detached, :session_ended})
    state = if state.socket, do: Out.close(state), else: state
    HerdrReload.Telemetry.event(:client_detach, id: short(state.id), reason: :session_ended)
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  # a crashed or stopped conn must not leave the broker holding its socket open
  @impl true
  def terminate(_reason, state), do: _ = Carry.unhold(Map.merge(%__MODULE__{}, state))

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  # --- pane mode ---

  defp pane_closed(state) do
    state = Out.out(%{state | detached: true}, {:detached, :pane_closed})
    state = if state.socket, do: Out.close(state), else: state
    HerdrReload.Telemetry.event(:client_detach, id: short(state.id), reason: :pane_closed)
    {:stop, :normal, state}
  end

  # --- input ---

  defp received(state, data) do
    case Wire.decode(state.buf <> data, Wire.max_client_frame()) do
      {:ok, frames, rest} ->
        state = Enum.reduce_while(frames, %{state | buf: rest}, &connected_frame/2)

        if state.socket, do: :inet.setopts(state.socket, active: :once)
        state

      # too large or undecodable: this connection only
      {:error, _} ->
        Out.drop(state)
    end
  end

  # a frame that closed the socket ({:detach}, a failed write) ends the read
  defp connected_frame(f, state) do
    state = frame(f, state)
    if state.socket, do: {:cont, state}, else: {:halt, state}
  end

  defp frame(f, state) do
    with true <- Schema.plain?(f) || {:error, "not plain data"},
         :ok <- Wire.validate_client_frame(f),
         :ok <- client_seq(f) do
      client_frame(f, state)
    else
      {:error, why} ->
        Out.out(state, {:notice, %{level: :warning, text: "frame rejected: " <> why}})
    end
  end

  # seqs from 2^62 are the conn's own (their acks are swallowed)
  defp client_seq({:input, w, _}) when w >= @internal_seq,
    do: {:error, "input: wire_seq too large"}

  defp client_seq(_frame), do: :ok

  defp client_frame({:input, w, ev}, %{pane: id} = state) when id != nil do
    cond do
      w <= state.acked ->
        Out.out(state, {:ack, w})

      # the panes may be freezing: unacked, the client resends it to the next VM
      handoff?() ->
        Out.drop(state)

      true ->
        state = %{state | last_seq: w, acked: w}

        state =
          case Pane.input(state.info.target, ev) do
            :ok -> state
            notice -> Out.out(state, notice)
          end

        state = if match?({:resize, _}, ev), do: repaint(own_resize(state, ev)), else: state
        Out.out(state, {:ack, w})
    end
  end

  defp client_frame({:input, w, ev}, state) do
    cond do
      w > state.last_seq ->
        send(state.session, {:input, self(), w, ev})
        own_resize(%{state | last_seq: w}, ev)

      w <= state.acked ->
        Out.out(state, {:ack, w})

      true ->
        state
    end
  end

  defp client_frame({:caps, m} = msg, state) do
    if state.session, do: send(state.session, msg)
    %{state | info: %{state.info | caps: m}}
  end

  defp client_frame({:detach}, %{pane: id} = state) when id != nil, do: Out.drop(state)

  defp client_frame({:detach} = msg, state) do
    send(state.session, msg)
    state
  end

  defp client_frame(_handshake_frame, state),
    do: Out.out(state, {:notice, %{level: :warning, text: "frame rejected: already attached"}})

  # the client's own resize: what a resume compares against
  defp own_resize(state, {:resize, %{cols: c, rows: r, cell_px: px}}) do
    size = %{cols: c, rows: r}
    Registry.update_value(__MODULE__.Registry, state.id, &%{&1 | size: size})
    %{state | info: %{state.info | size: size, cell_px: px}}
  end

  defp own_resize(state, _ev), do: state

  defp resized(%{pane: id} = state, info) when id != nil, do: repaint(%{state | info: info})

  defp resized(state, info) do
    new = {Map.take(info.size, [:cols, :rows]), info.cell_px}

    if new == {Map.take(state.info.size, [:cols, :rows]), state.info.cell_px} do
      %{state | info: info}
    else
      ev = {:resize, Map.put(elem(new, 0), :cell_px, info.cell_px)}
      send(state.session, {:input, self(), state.internal, ev})
      %{state | info: info, internal: state.internal + 1}
    end
  end

  defp repaint(state) do
    case pane_scene(state) do
      {:ok, nil} -> state
      {:ok, scene} -> Out.put(state, scene)
      {:failed, f} -> Out.failed(state, f)
    end
  end

  # PaneScene is editable code
  defp pane_scene(state),
    do:
      Guard.run_twice(Pane, :scene, [state.pane, state.info.size],
        scan: false,
        server: Store.reload_server()
      )

  defp meta(info, connected),
    do: %{
      kind: info.kind,
      target: info.target,
      size: Map.take(info.size, [:cols, :rows]),
      connected: connected
    }

  @doc false
  @spec short(binary) :: binary
  def short(id), do: binary_part(id, 0, min(8, byte_size(id)))
end
