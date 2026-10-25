defmodule HerdrServer.Client.Remote.Out do
  @moduledoc """
  Output scheduling and socket lifetime of a `Client.Remote` conn, as functions over its
  state: scenes and rows go into `Client.Outbox` and are flushed when the last flush is
  `frame_ms` old and the driver queue is empty (`send_pend == 0`); a reader that has not
  drained for `stuck_ms` is dropped like a lost socket. Other messages flush what is
  pending, then go at once. A dropped socket arms the grace timer.

  `Client.Outbox` is editable code: every call into it goes through `HerdrReload.Guard`
  (a failed reload rolls back and runs again on the old code). A call that still fails
  sends one error notice: a failed `put` sends that message unbatched and replaces the
  outbox with a fresh one (batching resumes, the next flush resends every row); a failed
  flush sends nothing until the next frame.
  """

  alias HerdrReload.Guard
  alias HerdrScene.Wire
  alias HerdrServer.App.Store
  alias HerdrServer.Client.Outbox
  alias HerdrServer.Client.Remote.Carry
  alias HerdrServer.Native.Link, as: NLink

  @registry HerdrServer.Client.Remote.Registry

  @doc "Queues a scene or rows in the outbox; a scene loses the root's sound command."
  @spec put(map, tuple) :: map
  def put(state, msg) do
    msg = local_only(msg)

    case outbox(:put, [state.outbox, msg]) do
      {:ok, outbox} ->
        %{state | outbox: outbox}

      {:failed, f} ->
        # a fresh outbox: the broken one never recovers, and the next scene resends in full
        state = %{state | outbox: %Outbox{}}
        state |> failed(f) |> write(msg)
    end
  end

  # [ui.sound] command is for in-VM clients: a socket client never gets a command to run
  defp local_only({:scene, %{chrome: %{props: %{sound: %{command: _} = snd}}} = scene}),
    do: {:scene, put_in(scene.chrome.props.sound, Map.delete(snd, :command))}

  defp local_only(msg), do: msg

  @doc "Writes the last scene with every row (an attach or resume)."
  @spec full(map) :: map
  def full(state) do
    case outbox(:full, [state.outbox]) do
      {:ok, {msgs, outbox}} -> write_all(%{state | outbox: outbox, last_flush: now()}, msgs)
      {:failed, f} -> failed(state, f)
    end
  end

  @doc "A guarded call into editable code failed: an error notice to the client."
  @spec failed(map, Guard.failure()) :: map
  def failed(state, f),
    do:
      write(state, {:notice, %{level: :error, text: "client output failed: #{Guard.message(f)}"}})

  defp outbox(fun, args),
    do: Guard.run_twice(Outbox, fun, args, scan: false, server: Store.reload_server())

  # a failing pending? still tries the (guarded) flush
  defp pending?(state), do: outbox(:pending?, [state.outbox]) != {:ok, false}

  @spec schedule(map) :: map
  def schedule(%{socket: nil} = state), do: state
  def schedule(%{frozen: true} = state), do: state
  def schedule(%{flush_timer: t} = state) when t != nil, do: state

  def schedule(state) do
    wait = state.last_flush + state.frame_ms - now()

    cond do
      not pending?(state) -> state
      wait > 0 -> later(state, wait)
      drained?(state.socket) -> flush(%{state | pend_since: nil})
      stuck?(state) -> drop(state)
      true -> later(%{state | pend_since: state.pend_since || now()}, state.frame_ms)
    end
  end

  # a reader that has not drained for stuck_ms is lost (grace applies)
  defp stuck?(%{pend_since: nil}), do: false
  defp stuck?(state), do: now() - state.pend_since > state.stuck_ms

  defp later(state, ms), do: %{state | flush_timer: Process.send_after(self(), :flush, ms)}

  @spec drained?(:gen_tcp.socket()) :: boolean
  def drained?(s), do: match?({:ok, [send_pend: 0]}, :inet.getstat(s, [:send_pend]))

  defp flush(%{socket: nil} = state), do: state

  # an empty flush (before an ack, say) starts no frame: the echo behind it goes at once
  defp flush(state) do
    case outbox(:flush, [state.outbox]) do
      {:ok, {[], outbox}} -> %{state | outbox: outbox}
      {:ok, {msgs, outbox}} -> write_all(%{state | outbox: outbox, last_flush: now()}, msgs)
      {:failed, f} -> failed(state, f)
    end
  end

  @doc "Sends `msg` now, after what is pending (arrival order)."
  @spec out(map, term) :: map
  def out(state, msg), do: state |> unstick() |> flush() |> write(msg)

  # a drained socket is not stuck: a stale pend_since would drop it early later
  defp unstick(%{pend_since: t, socket: s} = state) when t != nil and s != nil,
    do: if(drained?(s), do: %{state | pend_since: nil}, else: state)

  defp unstick(state), do: state

  @spec write_all(map, [term]) :: map
  def write_all(state, msgs), do: Enum.reduce(msgs, state, &write(&2, &1))

  @spec write(map, term) :: map
  def write(%{socket: nil} = state, _msg), do: state
  def write(%{frozen: true} = state, msg), do: %{state | frozen_out: [msg | state.frozen_out]}

  def write(state, msg) do
    case :gen_tcp.send(state.socket, Wire.encode(msg)) do
      :ok -> state
      {:error, _} -> drop(state)
    end
  end

  # --- connection ---

  @doc "Closes the socket a resume replaces (a stuck old reader gets no detached frame)."
  @spec replaced(map) :: map
  def replaced(state) do
    if drained?(state.socket),
      do: _ = :gen_tcp.send(state.socket, Wire.encode({:detached, :replaced}))

    %{close(state) | away_since: now()}
  end

  @doc "The socket is lost: close it and arm grace."
  @spec drop(map) :: map
  def drop(%{socket: nil} = state), do: state

  def drop(state) do
    state = close(state)
    Registry.update_value(@registry, state.id, &%{&1 | connected: false})
    away(%{state | buf: ""})
  end

  # DROP first: while the broker holds a dup the peer never sees our close. A plain close
  # waits (send_timeout) for queued output; a stuck reader never drains it.
  @spec close(map) :: map
  def close(%{socket: s} = state) do
    state = Carry.unhold(state)
    unless drained?(s), do: :inet.setopts(s, linger: {true, 0})
    :gen_tcp.close(s)
    if state.fd, do: NLink.fd_close(state.fd)
    %{state | socket: nil, fd: nil}
  end

  @spec away(map) :: map
  def away(state), do: arm(state, state.grace_ms)

  @doc "`{:grace, ref}` in `ms` stops the conn unless a socket comes first."
  @spec arm(map, non_neg_integer) :: map
  def arm(state, ms) do
    ref = make_ref()
    Process.send_after(self(), {:grace, ref}, ms)
    %{state | grace_ref: ref, away_since: now()}
  end

  @spec now() :: integer
  def now, do: System.monotonic_time(:millisecond)
end
