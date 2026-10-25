defmodule HerdrServer.Client.Remote do
  @moduledoc """
  One per socket client (`restart: :temporary`), registered under its `client_id` in
  `HerdrServer.Client.Remote.Registry`. It is the client pid its `Client.Session` talks
  to (attached through `Protocol.endpoint()` with `transport: :inline`), and it speaks
  `HerdrScene.Wire` on the socket that `Client.Socket` hands it with `resume/4`.

  Output: scenes and rows go through `Client.Outbox` (coalesced, only changed rows) and
  are flushed when the last flush is `frame_ms` old and the previous frames have left
  the driver queue (`send_pend == 0`), so a slow reader coalesces instead of queueing.
  Every other session message flushes what is pending first, then goes at once.

  Input (R8): a client frame is rejected with a warning notice unless it is plain data
  and valid; the connection stays. `{:input, w, ev}` is forwarded when `w > last_seq`,
  re-acked when `w <= acked`, dropped otherwise (in flight: its ack comes later), so a
  client resending unacked input after a reconnect applies it exactly once. A frame over
  the size limit, or one that does not decode, closes the socket.

  Grace (R9): when the socket goes, the conn (and its session) lingers `grace_ms`; a
  `resume/4` with the same `client_id` re-arms it: `{:attached, %{resumed: true}}`, a full
  scene, the input mode when not `:terminal`, and a resize when the size changed (an
  internal input with seq from 2^62, its ack swallowed). A resume while connected closes
  the old socket after `{:detached, :replaced}`. Expiry stops the conn normally, which
  ends the session. A session that ends sends `{:detached, reason}` (if it did not) and
  stops the conn.
  """
  use GenServer, restart: :temporary

  alias HerdrScene.{Protocol, Wire}
  alias HerdrServer.Client.{Outbox, Socket}
  alias HerdrServer.Persist.Schema

  @internal_seq 4_611_686_018_427_387_904
  @immediate [:notice, :alert, :handoff, :clipboard, :bell, :open_url, :damage]

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
            grace_ms: 60_000

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

  @doc "Handoff PREPARE for every conn (Task 5 freezes them; nothing yet)."
  @spec prepare_all() :: :ok
  def prepare_all, do: :ok

  @doc "Handoff THAW for every conn (Task 5)."
  @spec thaw_all() :: :ok
  def thaw_all, do: :ok

  @doc false
  # by Client.Socket after giving `pid` the socket; `buf` is what followed the attach frame
  @spec resume(pid, :gen_tcp.socket(), map, binary) :: :ok | :error
  def resume(pid, socket, info, buf) do
    GenServer.call(pid, {:resume, socket, info, buf})
  catch
    :exit, _ -> :error
  end

  @impl true
  def init(info) do
    case Registry.register(__MODULE__.Registry, info.client_id, meta(info, false)) do
      {:ok, _} -> attach(info)
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
        HerdrReload.Telemetry.event(:client_attach,
          id: short(info.client_id),
          kind: info.kind,
          target: info.target,
          cols: info.size.cols,
          rows: info.size.rows
        )

        cfg = Application.get_env(:herdr_server, :client_socket, [])

        state = %__MODULE__{
          id: info.client_id,
          info: info,
          session: session,
          session_ref: Process.monitor(session),
          frame_ms: Keyword.get(cfg, :frame_ms, 8),
          grace_ms: Keyword.get(cfg, :grace_ms, 60_000)
        }

        # the socket comes with resume/4; a conn that never gets one ends like a drop
        {:ok, away(state)}

      {:error, why} ->
        {:stop, {:attach, why}}
    end
  end

  @impl true
  def handle_call({:resume, s, info, buf}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = if state.socket, do: replaced(state), else: state

    unless state.fresh,
      do:
        HerdrReload.Telemetry.event(:client_reconnect,
          id: short(state.id),
          away_ms: now() - (state.away_since || now())
        )

    resumed = not state.fresh
    state = resized(state, info)
    Registry.update_value(__MODULE__.Registry, state.id, fn _ -> meta(info, true) end)

    state = %{state | socket: s, buf: "", grace_ref: nil, away_since: nil, fresh: false}
    state = write(state, {:attached, %{resumed: resumed, session: Socket.session_name()}})
    {msgs, outbox} = Outbox.full(state.outbox)
    state = write_all(%{state | outbox: outbox, last_flush: now()}, msgs)
    state = if state.mode != :terminal, do: write(state, {:input_mode, state.mode}), else: state
    {:reply, :ok, received(state, buf)}
  end

  @impl true
  def handle_info({:tcp, s, data}, %{socket: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, received(state, data)}
  end

  def handle_info({:tcp_closed, s}, %{socket: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, drop(state)}
  end

  def handle_info({:tcp_error, s, _}, %{socket: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, drop(state)}
  end

  def handle_info({:scene, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, schedule(%{state | outbox: Outbox.put(state.outbox, msg)})}
  end

  def handle_info({:rows, _, _, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, schedule(%{state | outbox: Outbox.put(state.outbox, msg)})}
  end

  # our own resizes
  def handle_info({:ack, w}, state) when w >= @internal_seq,
    do: {:noreply, Map.merge(%__MODULE__{}, state)}

  def handle_info({:ack, w} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, out(%{state | acked: max(state.acked, w)}, msg)}
  end

  def handle_info({:input_mode, m} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, out(%{state | mode: m}, msg)}
  end

  def handle_info({:detached, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, out(%{state | detached: true}, msg)}
  end

  def handle_info(msg, state) when is_tuple(msg) and elem(msg, 0) in @immediate do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, out(state, msg)}
  end

  def handle_info(:flush, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, schedule(%{state | flush_timer: nil})}
  end

  def handle_info({:grace, ref}, %{grace_ref: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    HerdrReload.Telemetry.event(:client_detach, id: short(state.id), reason: :grace_expired)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{session_ref: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    state = if state.detached, do: state, else: out(state, {:detached, :session_ended})
    if state.socket, do: :gen_tcp.close(state.socket)
    HerdrReload.Telemetry.event(:client_detach, id: short(state.id), reason: :session_ended)
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  # --- input ---

  defp received(state, data) do
    case Wire.decode(state.buf <> data, Wire.max_client_frame()) do
      {:ok, frames, rest} ->
        state = Enum.reduce(frames, %{state | buf: rest}, &frame/2)
        if state.socket, do: :inet.setopts(state.socket, active: :once)
        state

      # too large or undecodable: this connection only
      {:error, _} ->
        drop(state)
    end
  end

  defp frame(f, state) do
    with true <- Schema.plain?(f) || {:error, "not plain data"},
         :ok <- Wire.validate_client_frame(f) do
      client_frame(f, state)
    else
      {:error, why} -> out(state, {:notice, %{level: :warning, text: "frame rejected: " <> why}})
    end
  end

  defp client_frame({:input, w, ev}, state) do
    cond do
      w > state.last_seq ->
        send(state.session, {:input, self(), w, ev})
        %{state | last_seq: w}

      w <= state.acked ->
        out(state, {:ack, w})

      true ->
        state
    end
  end

  defp client_frame({:caps, m} = msg, state) do
    send(state.session, msg)
    %{state | info: %{state.info | caps: m}}
  end

  defp client_frame({:detach} = msg, state) do
    send(state.session, msg)
    state
  end

  defp client_frame(_handshake_frame, state),
    do: out(state, {:notice, %{level: :warning, text: "frame rejected: already attached"}})

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

  # --- output ---

  defp schedule(%{socket: nil} = state), do: state
  defp schedule(%{flush_timer: t} = state) when t != nil, do: state

  defp schedule(state) do
    wait = state.last_flush + state.frame_ms - now()

    cond do
      not Outbox.pending?(state.outbox) ->
        state

      wait <= 0 and drained?(state.socket) ->
        flush(state)

      true ->
        delay = if wait > 0, do: wait, else: state.frame_ms
        %{state | flush_timer: Process.send_after(self(), :flush, delay)}
    end
  end

  defp drained?(s), do: match?({:ok, [send_pend: 0]}, :inet.getstat(s, [:send_pend]))

  defp flush(%{socket: nil} = state), do: state

  defp flush(state) do
    {msgs, outbox} = Outbox.flush(state.outbox)
    write_all(%{state | outbox: outbox, last_flush: now()}, msgs)
  end

  # in arrival order: what is pending goes first
  defp out(state, msg), do: state |> flush() |> write(msg)

  defp write_all(state, msgs), do: Enum.reduce(msgs, state, &write(&2, &1))

  defp write(%{socket: nil} = state, _msg), do: state

  defp write(state, msg) do
    case :gen_tcp.send(state.socket, Wire.encode(msg)) do
      :ok -> state
      {:error, _} -> drop(state)
    end
  end

  # --- connection ---

  defp replaced(state) do
    _ = :gen_tcp.send(state.socket, Wire.encode({:detached, :replaced}))
    :gen_tcp.close(state.socket)
    %{state | socket: nil, away_since: now()}
  end

  defp drop(state) do
    :gen_tcp.close(state.socket)
    Registry.update_value(__MODULE__.Registry, state.id, &%{&1 | connected: false})
    away(%{state | socket: nil, buf: ""})
  end

  defp away(state) do
    ref = make_ref()
    Process.send_after(self(), {:grace, ref}, state.grace_ms)
    %{state | grace_ref: ref, away_since: now()}
  end

  defp meta(info, connected),
    do: %{
      kind: info.kind,
      target: info.target,
      size: Map.take(info.size, [:cols, :rows]),
      connected: connected
    }

  defp short(id), do: binary_part(id, 0, min(8, byte_size(id)))

  defp now, do: System.monotonic_time(:millisecond)
end
