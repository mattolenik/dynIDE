defmodule HerdrTerm.Remote.Conn do
  @moduledoc """
  The remote client's transport: the endpoint a `HerdrTerm.Client` (`transport:
  :inline`) attaches to, speaking `HerdrScene.Wire` to the server over the local client
  socket (`{:unix, socket_path, token_path}`, first frame `{:auth, token}`) or an ssh
  relay port (`{:ssh, host, session}`, R13; the relay sends the auth).

  `{:attach, req}` from Render stores Render's pid, size, cell_px and caps, replies at
  once with this process as the session (rows MFA `no_rows/1`: inline rows arrive in
  the scene) and (re)connects, so a restarted Render gets a full scene. Every
  connection sends `{:attach, %{version: 1, ...}}` with the latest size.

  Input (R8): each `{:input, from, seq, ev}` gets a wire seq of this process's own and
  stays pending until the server's `{:ack, wire_seq}`, which goes back to `from` as
  `{:ack, seq}`. Pending input is sent while attached and not held; every
  `{:attached, _}` resends all pending input in wire order. `{:handoff, %{phase:
  :begin | :released}}` holds input, `:aborted` releases it (R12). Pane targets filter
  keys through `HerdrTerm.Remote.Keys` (ctrl+b q detaches the VM).

  Every other server frame goes to Render; the last scene is kept with its inline rows
  dropped, to show a client-local notice (`HerdrTerm.Remote.Notice`): while
  disconnected (R14, backoff `{min_ms, max_ms}` doubling, reset on attach), and when a
  frame cannot be decoded (R7; the socket is closed, a reconnect after the longest
  delay resyncs). `{:refused, why}` and `{:detached, _}` stop reconnecting; a refusal
  ends the VM (`HerdrTerm.Client.local_exit/1`), a detach does through `Tty.Owner`.
  """

  use GenServer

  require Logger

  alias HerdrScene.{Scene, Wire}
  alias HerdrTerm.Client
  alias HerdrTerm.Remote.{Args, Keys, Notice}

  @decode_text "server sent a term this client cannot decode; same commit on both ends?"
  @connect_ms 2_000

  defstruct [
    :transport,
    :session,
    :target,
    :client_id,
    :render,
    :size,
    :cell_px,
    :sock,
    :scene,
    :notice,
    :timer,
    caps: %{},
    backoff: {100, 5000},
    delay: 100,
    buf: "",
    attached: false,
    hold: false,
    stopped: false,
    keys: :idle,
    next: 1,
    sent: 0,
    pending: %{}
  ]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Rows MFA of the attach reply: inline rows come with the scene, nothing to fetch."
  def no_rows(_id), do: nil

  @impl true
  def init(opts) do
    {min, _} = backoff = Keyword.get(opts, :backoff, {100, 5000})

    {:ok,
     %__MODULE__{
       transport: Keyword.fetch!(opts, :transport),
       session: Keyword.get(opts, :session),
       target: Keyword.get(opts, :target, :session),
       client_id: Keyword.get_lazy(opts, :client_id, &client_id/0),
       backoff: backoff,
       delay: min,
       keys: Keys.new()
     }}
  end

  defp client_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  @impl true
  def handle_call({:attach, req}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = %{state | render: req.client, size: req.size, cell_px: req.cell_px, caps: req.caps}

    {:reply, {:ok, self(), %{rows: {__MODULE__, :no_rows, []}}}, close(state),
     {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, connect(state)}
  end

  @impl true
  def handle_info({:connect, tag}, %{sock: nil, timer: {tag, _}} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, connect(%{state | timer: nil})}
  end

  def handle_info({:tcp, s, data}, %{sock: s} = state) do
    state = Map.merge(%__MODULE__{}, state)

    case :inet.setopts(s, active: :once) do
      :ok -> {:noreply, data(state, data)}
      {:error, _} -> {:noreply, lost(state, "disconnected from the server")}
    end
  end

  def handle_info({s, {:data, data}}, %{sock: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, data(state, data)}
  end

  def handle_info({:tcp_closed, s}, %{sock: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, lost(state, "disconnected from the server")}
  end

  def handle_info({:tcp_error, s, _why}, %{sock: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, lost(state, "disconnected from the server")}
  end

  def handle_info({s, {:exit_status, n}}, %{sock: s} = state) do
    state = Map.merge(%__MODULE__{}, state)
    # the port is gone already: close/1 must not close it again
    {:noreply, lost(%{state | sock: nil}, "ssh relay exited (#{n})")}
  end

  def handle_info({:input, from, seq, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = resize(state, ev)

    {action, keys} =
      if match?({:pane, _, _}, state.target),
        do: Keys.filter(state.keys, ev),
        else: {:forward, state.keys}

    {:noreply, input(%{state | keys: keys}, action, {from, seq}, ev)}
  end

  # stale socket or port messages, a stale {:connect, tag}
  def handle_info(msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.debug("remote conn: ignored #{inspect(msg)}")
    {:noreply, state}
  end

  # connection

  defp connect(%{stopped: true} = state), do: state

  defp connect(state) do
    case open(state.transport) do
      {:ok, sock} ->
        Logger.info("remote: connected (#{inspect(state.transport)})")
        state = %{state | sock: sock}

        send_frame(
          state,
          {:attach,
           %{
             version: Wire.version(),
             client_id: state.client_id,
             session: state.session,
             kind: :term,
             size: state.size,
             cell_px: state.cell_px,
             caps: state.caps,
             target: state.target
           }}
        )

        state

      {:error, why} ->
        Logger.warning("remote: cannot connect: #{inspect(why)}")
        retry(state, "cannot reach the server")
    end
  end

  defp open({:unix, path, token_path}) do
    opts = [:binary, packet: :raw, active: :once]

    with {:ok, token} <- File.read(token_path),
         {:ok, s} <- :gen_tcp.connect({:local, path}, 0, opts, @connect_ms) do
      _ = :gen_tcp.send(s, Wire.encode({:auth, String.trim(token)}))
      {:ok, s}
    end
  end

  defp open({:ssh, host, _session}) do
    {exe, args} = Args.ssh_command(host, System.get_env())

    case System.find_executable(exe) do
      nil -> {:error, {:not_found, exe}}
      path -> {:ok, Port.open({:spawn_executable, path}, [:binary, :exit_status, args: args])}
    end
  end

  defp send_frame(%{sock: nil}, _frame), do: :ok

  defp send_frame(%{transport: {:ssh, _, _}, sock: port}, frame),
    do: port_op(fn -> Port.command(port, Wire.encode(frame)) end)

  defp send_frame(%{sock: s}, frame), do: :gen_tcp.send(s, Wire.encode(frame))

  # the relay can exit before its {:exit_status, _} is handled: the port is then closed
  # and Port.command/close raise ArgumentError; that exit status still arrives
  defp port_op(fun) do
    fun.()
  rescue
    ArgumentError -> :ok
  end

  defp close(state) do
    case state.sock do
      nil -> :ok
      s when elem(state.transport, 0) == :ssh -> port_op(fn -> Port.close(s) end)
      s -> :gen_tcp.close(s)
    end

    with {_tag, t} <- state.timer, do: Process.cancel_timer(t)
    %{state | sock: nil, timer: nil, buf: "", attached: false, hold: false}
  end

  defp lost(state, text), do: state |> close() |> retry(text)

  defp retry(%{stopped: true} = state, _text), do: state

  defp retry(state, text) do
    {_, max} = state.backoff
    state = show(state, %{level: :warning, text: "#{text}, reconnecting in #{state.delay} ms"})
    tag = make_ref()
    timer = {tag, Process.send_after(self(), {:connect, tag}, state.delay)}
    %{state | timer: timer, delay: min(state.delay * 2, max)}
  end

  defp show(state, notice) do
    if state.render,
      do:
        send(state.render, {:scene, Notice.put(state.scene || Notice.blank(state.size), notice)})

    %{state | notice: notice}
  end

  # server frames

  defp data(state, bin) do
    case Wire.decode(state.buf <> bin, Wire.max_server_frame()) do
      {:ok, frames, rest} ->
        Enum.reduce(frames, %{state | buf: rest}, &frame(&2, &1))

      {:error, :bad_term} ->
        Logger.error("remote: #{@decode_text}")
        # the resync's full scene likely fails again, and attach resets the backoff:
        # wait the longest delay so a term this client lacks is no reconnect loop
        lost(%{state | delay: elem(state.backoff, 1)}, @decode_text)

      {:error, :too_large} ->
        lost(state, "server frame over the size limit")
    end
  end

  defp frame(state, {:attached, info}) do
    Logger.info("remote: attached #{inspect(info)}")
    {min, _} = state.backoff
    if state.notice && state.scene, do: to_render(state, {:scene, state.scene})
    flush(%{state | attached: true, hold: false, delay: min, sent: 0, notice: nil})
  end

  defp frame(state, {:refused, why}) do
    Logger.error("remote: refused by the server: #{inspect(why)}")
    state = state |> close() |> show(%{level: :error, text: "refused: #{why}"})
    Client.local_exit({:refused, why})
    %{state | stopped: true}
  end

  defp frame(state, {:ack, w}) do
    case Map.pop(state.pending, w) do
      {{{pid, seq}, _ev}, pending} ->
        send(pid, {:ack, seq})
        %{state | pending: pending}

      {_, pending} ->
        %{state | pending: pending}
    end
  end

  defp frame(state, {:handoff, %{phase: p}} = msg) when p in [:begin, :released] do
    to_render(state, msg)
    %{state | hold: true}
  end

  defp frame(state, {:handoff, %{phase: :aborted}} = msg) do
    to_render(state, msg)
    flush(%{state | hold: false})
  end

  defp frame(state, {:scene, %Scene{} = scene} = msg) do
    to_render(state, msg)
    %{state | scene: %{scene | panes: Enum.map(scene.panes, &%{&1 | rows: {:inline, []}})}}
  end

  defp frame(state, {:detached, _} = msg) do
    to_render(state, msg)
    %{state | stopped: true}
  end

  defp frame(state, msg) do
    to_render(state, msg)
    state
  end

  defp to_render(state, msg), do: if(state.render, do: send(state.render, msg))

  # input

  defp resize(state, {:resize, %{cols: c, rows: r} = m}),
    do: %{state | size: %{cols: c, rows: r}, cell_px: Map.get(m, :cell_px)}

  defp resize(state, _ev), do: state

  defp input(state, :forward, reply, ev), do: enqueue(state, [ev], reply)
  defp input(state, {:forward, evs}, reply, _ev), do: enqueue(state, evs, reply)

  defp input(state, :swallow, {pid, seq}, _ev) do
    send(pid, {:ack, seq})
    state
  end

  defp input(state, :detach, {pid, seq}, _ev) do
    send(pid, {:ack, seq})
    send_frame(state, {:detach})
    Client.local_exit({:detached, :requested})
    %{state | stopped: true}
  end

  # the reply goes with the last event; earlier ones are acked silently
  defp enqueue(state, evs, reply) do
    replies = List.duplicate(nil, length(evs) - 1) ++ [reply]

    {pending, next} =
      Enum.zip(replies, evs)
      |> Enum.reduce({state.pending, state.next}, fn {r, ev}, {p, n} ->
        {Map.put(p, n, {r, ev}), n + 1}
      end)

    flush(%{state | pending: pending, next: next})
  end

  defp flush(%{attached: true, hold: false} = state) do
    ws = state.pending |> Map.keys() |> Enum.filter(&(&1 > state.sent)) |> Enum.sort()
    Enum.each(ws, &send_frame(state, {:input, &1, elem(state.pending[&1], 1)}))
    %{state | sent: Enum.max([state.sent | ws])}
  end

  defp flush(state), do: state
end
