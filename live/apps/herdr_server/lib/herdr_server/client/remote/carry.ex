defmodule HerdrServer.Client.Remote.Carry do
  @moduledoc """
  Handoff carry (R11) of a `Client.Remote` conn, as functions over its state: the broker
  hold of `client/<client_id>` (blob `%{v: 1, client_id, info, acked, buffer, prepared}`,
  fd a dup of the socket), the PREPARE freeze, and the adopted entry's decode on the new
  VM. See `Client.Remote` for the protocol.
  """

  require Logger

  alias HerdrScene.Wire
  alias HerdrServer.Client.Remote
  alias HerdrServer.Client.Remote.Out
  alias HerdrServer.Client.Socket
  alias HerdrServer.Handoff.Link
  alias HerdrServer.Native.Link, as: NLink

  @max_carried 1_048_576
  @sent_ms 200

  @doc "A blob whose info can start a session, or `:error`."
  @spec decode(binary) :: {:ok, map} | :error
  def decode(blob) do
    with %{v: 1, client_id: id, info: info, acked: acked, buffer: buf} = b
         when is_binary(id) and is_integer(acked) and is_binary(buf) <-
           :erlang.binary_to_term(blob, [:safe]),
         :ok <- Wire.validate_client_frame({:attach, info}),
         # pane conns are never held; such an entry is not ours to resume
         :session <- info.target do
      {:ok, b}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "The adopted socket when the blob was frozen for this handoff, else `{:grace, b}`."
  @spec carried(map, [term]) :: {:ok, :gen_tcp.socket(), term} | {:grace, map}
  def carried(%{prepared: true, buffer: buf} = b, [fd]) when byte_size(buf) <= @max_carried do
    with {:ok, raw} <- NLink.fd_raw(fd),
         {:ok, s} <- :gen_tcp.fdopen(raw, [:local | Socket.socket_opts()]),
         do: {:ok, s, fd},
         else: (_ -> {:grace, b})
  end

  def carried(b, _fds), do: {:grace, b}

  @spec held_event(binary, boolean) :: :ok
  def held_event(id, carried),
    do: HerdrReload.Telemetry.event(:client_held, id: Remote.short(id), carried: carried)

  @doc "Gives the entry back to the broker and closes what it handed us: `:ignore`."
  @spec not_carried(binary, :gen_tcp.socket() | nil, [term]) :: :ignore
  def not_carried(key, s, fds) do
    :ok = Link.unclaim(key)
    if s, do: :gen_tcp.close(s)
    Enum.each(fds, &NLink.fd_close/1)
    :ignore
  end

  @spec freeze(map) :: map
  def freeze(%{socket: nil} = state), do: %{state | frozen: true}

  # Pending scenes stay in the outbox (the next VM sends a full scene; THAW flushes them):
  # a send could block for send_timeout. A socket whose queued output does not leave the
  # driver in @sent_ms is dropped, not carried: those bytes would interleave with the next
  # VM's frames. Its client reconnects.
  def freeze(state) do
    _ = :inet.setopts(state.socket, active: false)
    state = drain_tcp(state)

    cond do
      state.socket == nil -> %{state | frozen: true}
      sent(state.socket, Out.now() + @sent_ms) -> %{update_hold(state, true) | frozen: true}
      true -> %{Out.drop(state) | frozen: true}
    end
  end

  # the message `active: :once` may already have delivered
  defp drain_tcp(%{socket: s} = state) do
    receive do
      {:tcp, ^s, data} -> drain_tcp(%{state | buf: state.buf <> data})
      {:tcp_closed, ^s} -> Out.drop(state)
      {:tcp_error, ^s, _} -> Out.drop(state)
    after
      0 -> state
    end
  end

  defp sent(s, deadline) do
    cond do
      Out.drained?(s) ->
        true

      Out.now() >= deadline ->
        false

      true ->
        receive do
        after
          5 -> sent(s, deadline)
        end
    end
  end

  @spec hold_mod() :: module
  def hold_mod, do: Application.get_env(:herdr_server, :client_hold, Link)

  # no broker, nothing to dup (a dup would also keep the peer from seeing our close)
  defp holding?, do: hold_mod() != Link or Link.enabled?()

  defp key(state), do: "client/" <> state.id

  # prepared: frozen for this handoff, so the stream is at a frame boundary plus `buffer`
  defp blob(state, prepared),
    do:
      :erlang.term_to_binary(%{
        v: 1,
        client_id: state.id,
        info: state.info,
        acked: state.acked,
        buffer: state.buf,
        prepared: prepared
      })

  @doc "HOLDs the conn's socket in the broker (session conns with a socket only)."
  @spec hold(map) :: map
  def hold(%{socket: nil} = state), do: state
  # pane conns are not carried across a handoff (R17)
  def hold(%{pane: id} = state) when id != nil, do: state

  def hold(state) do
    with true <- holding?(),
         {:ok, n} <- :inet.getfd(state.socket),
         {:ok, fd} <- NLink.fd_dup(n) do
      :ok = hold_mod().hold(key(state), blob(state, false), [fd])
      # the broker got its own dup; ours must not outlive a close
      _ = NLink.fd_close(fd)
      %{state | held: true}
    else
      false ->
        state

      {:error, why} ->
        Logger.warning("client #{Remote.short(state.id)}: not held: #{inspect(why)}")
        state
    end
  end

  @spec update_hold(map, boolean) :: map
  def update_hold(state, prepared \\ false)

  def update_hold(%{held: true} = state, prepared) do
    :ok = hold_mod().update(key(state), blob(state, prepared))
    state
  end

  def update_hold(state, _prepared), do: state

  @spec unhold(map) :: map
  def unhold(%{held: true} = state) do
    :ok = hold_mod().drop(key(state))
    %{state | held: false}
  end

  def unhold(state), do: state
end
