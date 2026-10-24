defmodule HerdrTerm.Client.Term.Input do
  @moduledoc """
  Host-tty bytes to neutral events. Holds the `Parse` state, subscribes itself
  to the tty through `Tty.Owner` on init, and on start writes the kitty flags
  query and DA1 and opens their reply windows (500ms). Replies are consumed
  here (kept in `replies`).

  Each event takes the fast path (contract decision 6: the focused pane's
  write MFA from `:persistent_term`, read per event) or goes to the session
  as `{:input, self(), seq, event}`. After a slow event every later event is
  held until `{:ack, seq}`. Key releases always go slow. Delivery is
  at-least-once: an unacked event is re-sent first to the next session. Events before the first `{:session, pid}` (sent
  by Render after each attach) are queued. A buffered ESC is flushed after 25ms.
  """

  use GenServer

  require Logger

  alias HerdrScene.Protocol
  alias HerdrTerm.{Client, Kernel, SafeApply}
  alias HerdrTerm.Client.Term.Input.Parse
  alias HerdrTerm.Tty.Owner

  @esc_ms 25
  @window_ms 500

  defstruct [
    :id,
    :tty,
    :session,
    :inflight,
    :esc,
    parse: Parse.new(),
    seq: 0,
    queue: [],
    replies: %{}
  ]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Client.via(opts[:id], :input))

  @doc "Feeds one already-parsed event (e.g. a resize from `Tty.Owner`)."
  def event(input, ev), do: GenServer.cast(input, {:event, ev})

  @impl true
  def init(opts) do
    owner = Client.via(opts[:id], :tty_owner)
    :ok = Owner.subscribe(owner, self())
    tty = Owner.tty(owner)
    Kernel.tty().write(tty, ["\e[?u", "\e[c"])
    deadline = now() + @window_ms

    parse =
      Parse.new()
      |> Parse.open_window(:kitty_flags, deadline)
      |> Parse.open_window(:da1, deadline)

    # a restarted Input asks Render for the current session
    GenServer.cast(Client.via(opts[:id], :render), {:input_up, self()})
    {:ok, %__MODULE__{id: opts[:id], tty: tty, parse: parse}}
  end

  @impl true
  def handle_cast({:event, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, enqueue(state, [ev])}
  end

  @impl true
  def handle_info({:tty_input, bin}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {items, parse} = state.parse |> Parse.expire_windows(now()) |> then(&Parse.events(bin, &1))
    state = arm_esc(%{state | parse: parse})
    {:noreply, enqueue(state, items)}
  end

  def handle_info({:esc_flush, ref}, %{esc: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {items, parse} = Parse.flush(state.parse)
    {:noreply, enqueue(%{state | parse: parse, esc: nil}, items)}
  end

  def handle_info({:esc_flush, _stale}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  def handle_info({:ack, seq}, %{inflight: {seq, _}} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, drain(%{state | inflight: nil})}
  end

  def handle_info({:ack, _seq}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  # at-least-once: the next session gets the unacked event first
  def handle_info({:session, nil}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | session: nil}}
  end

  def handle_info({:session, pid}, state) do
    state = Map.merge(%__MODULE__{}, state)

    queue =
      case state.inflight do
        {_seq, ev} -> [ev | state.queue]
        nil -> state.queue
      end

    {:noreply, drain(%{state | session: pid, inflight: nil, queue: queue})}
  end

  defp arm_esc(%{parse: %Parse{buffer: "\e" <> _}} = state) do
    ref = make_ref()
    Process.send_after(self(), {:esc_flush, ref}, @esc_ms)
    %{state | esc: ref}
  end

  defp arm_esc(state), do: %{state | esc: nil}

  defp enqueue(state, items) do
    {replies, events} = Enum.split_with(items, &match?({:reply, _, _}, &1))

    replies =
      Enum.reduce(replies, state.replies, fn {:reply, kind, data}, acc ->
        Logger.debug("tty reply #{kind}: #{inspect(data)}")
        Map.put(acc, kind, data)
      end)

    drain(%{state | replies: replies, queue: state.queue ++ events})
  end

  defp drain(%{session: s, inflight: nil, queue: [ev | rest]} = state) when is_pid(s) do
    state = %{state | queue: rest}

    case fast(ev, :persistent_term.get(Protocol.fast_path_key(), nil)) do
      {m, f, a} ->
        SafeApply.run(m, f, [ev | a])
        drain(state)

      nil ->
        seq = state.seq + 1
        send(s, {:input, self(), seq, ev})
        %{state | seq: seq, inflight: {seq, ev}}
    end
  end

  defp drain(state), do: state

  defp fast({:key, %{event: :release}}, _fast), do: nil

  defp fast({:key, %{key: k, mods: m}}, %{passthrough: true, write: {_, _, _} = w, intercept: i}),
    do: if(MapSet.member?(i, {k, m}), do: nil, else: w)

  defp fast(_ev, _fast), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
