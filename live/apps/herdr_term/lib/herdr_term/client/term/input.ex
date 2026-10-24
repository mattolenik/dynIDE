defmodule HerdrTerm.Client.Term.Input do
  @moduledoc """
  Host-tty bytes to neutral events. Holds the `Parse` state, subscribes itself
  to the tty through `Tty.Owner` on init and opens the kitty flags and DA1
  reply windows (500ms): the tty kernel's open already sent that probe, and
  replies arriving after its own 250ms deadline come in as input. Replies are
  consumed here (kept in `replies`).

  Each event takes the fast path (contract decision 6: the focused pane's
  write MFA from `:persistent_term`, read per event) or goes to the session
  as `{:input, self(), seq, event}`. After a slow event every later event is
  held until `{:ack, seq}`. Key releases always go slow, and so does every event of an
  inline client (`transport: :inline`, a socket client: the fast path is the server VM's). The fast path also needs this
  client's own input mode to be `:terminal`: the session sends `{:input_mode, mode}`
  before the ack of the event that changed it, so the ack-hold orders it before the next
  event; a new session resets it to `:terminal`. Delivery is
  at-least-once: an unacked event is re-sent first to the next session. Events before the first `{:session, pid}` (sent
  by Render after each attach) are queued. A buffered ESC is flushed after 25ms.

  Host colours: after the startup windows (500ms) and on `{:tty_resumed}`, Input asks
  the host for its colour scheme (`CSI ? 996 n`), default fg/bg (OSC 10/11) and palette
  (OSC 4, 0..255) with a 1s `:colors` window. When all 258 colours arrived or the window
  closed, and the host answered anything, the session gets
  `{:caps, %{colors: %{fg, bg, palette}, scheme}}` (rgb `{r, g, b}`, unanswered fg/bg/
  scheme nil) and Render `{:host_colors, %{fg, bg}}`; a later unsolicited scheme report
  (mode 2031) sends `{:caps, %{scheme: s}}`. The latest caps go to every new session.

  Parse runs through `HerdrReload.Guard`: a failing chunk is dropped (logged) and the parser
  state, queue and in-flight event stay as they were. `{:tty_resumed}` and
  `{:exit, :tty, _}` are forwarded to `Tty.Owner` (modes, repaint, local exit).

  Mouse events go through `Hit.route/4` (guarded; a failure passes the event unchanged)
  against Render's latest `{:chrome_hits, hits}` before they are queued: over chrome they
  become `{:chrome, path, action}`, elsewhere they pass byte-for-byte as `{:mouse, ...}`.
  """

  use GenServer

  require Logger

  alias HerdrReload.Guard
  alias HerdrScene.Protocol
  alias HerdrTerm.{Client, Kernel}
  alias HerdrTerm.Client.Term.Hit
  alias HerdrTerm.Client.Term.Input.Parse
  alias HerdrTerm.Tty.Owner

  @esc_ms 25
  @window_ms 500
  @colors_ms 1000
  @color_queries IO.iodata_to_binary([
                   "\e[?996n\e]10;?\e\\\e]11;?\e\\",
                   for(n <- 0..255, do: "\e]4;#{n};?\e\\")
                 ])

  defstruct [
    :id,
    :tty,
    :session,
    :inflight,
    :esc,
    # `colors`: the answers so far while a colour query is out; `caps`: the latest sent
    :colors,
    :caps,
    parse: Parse.new(),
    seq: 0,
    mode: :terminal,
    queue: [],
    replies: %{},
    # chrome hit testing (`Hit.route/4`): Render's hits and the grab / last left press
    hits: [],
    grab: nil,
    inline: false
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
    deadline = now() + @window_ms

    parse =
      Enum.reduce([:kitty_flags, :da1], Parse.new(), fn kind, p ->
        case Guard.run_twice(Parse, :open_window, [p, kind, deadline]) do
          {:ok, p} -> p
          {:failed, _} -> p
        end
      end)

    Process.send_after(self(), :query_colors, @window_ms)
    # a restarted Input asks Render for the current session
    GenServer.cast(Client.via(opts[:id], :render), {:input_up, self()})

    {:ok,
     %__MODULE__{
       id: opts[:id],
       tty: tty,
       parse: parse,
       inline: Keyword.get(opts, :transport) == :inline
     }}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  @impl true
  def handle_cast({:event, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, enqueue(state, [ev])}
  end

  @impl true
  def handle_info({:tty_input, bin}, state) do
    state = Map.merge(%__MODULE__{}, state)

    with {:ok, parse} <- Guard.run_twice(Parse, :expire_windows, [state.parse, now()]),
         {:ok, {items, parse}} <- Guard.run_twice(Parse, :events, [bin, parse]) do
      {:noreply, enqueue(arm_esc(%{state | parse: parse}), items)}
    else
      {:failed, _} -> {:noreply, state}
    end
  end

  def handle_info({:esc_flush, ref}, %{esc: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)

    case Guard.run_twice(Parse, :flush, [state.parse]) do
      {:ok, {items, parse}} -> {:noreply, enqueue(%{state | parse: parse, esc: nil}, items)}
      {:failed, _} -> {:noreply, %{state | esc: nil}}
    end
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

  def handle_info({:input_mode, mode}, state) when is_atom(mode) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | mode: mode}}
  end

  # at-least-once: the next session gets the unacked event first
  def handle_info({:session, nil}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | session: nil}}
  end

  # the same session again (Render answers both its attach and our :input_up): no resend
  def handle_info({:session, pid}, %{session: pid} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  def handle_info({:session, pid}, state) do
    state = Map.merge(%__MODULE__{}, state)

    queue =
      case state.inflight do
        {_seq, ev} -> [ev | state.queue]
        nil -> state.queue
      end

    state = publish(%{state | session: pid}, state.caps)
    {:noreply, drain(%{state | inflight: nil, queue: queue, mode: :terminal})}
  end

  def handle_info(:query_colors, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, query_colors(state)}
  end

  def handle_info({:colors_done, ref}, %{colors: %{ref: ref}} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, colors_done(state)}
  end

  def handle_info({:colors_done, _stale}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  def handle_info({:tty_resumed} = msg, state) do
    {:noreply, state} = to_owner(msg, state)
    {:noreply, query_colors(state)}
  end

  def handle_info({:chrome_hits, hits}, state) when is_list(hits) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | hits: hits}}
  end

  def handle_info({:exit, :tty, _} = msg, state), do: to_owner(msg, state)

  def handle_info(msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.debug("input: ignored #{inspect(msg)}")
    {:noreply, state}
  end

  defp to_owner(msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    if pid = Client.whereis(state.id, :tty_owner), do: send(pid, msg)
    {:noreply, state}
  end

  defp arm_esc(%{parse: %Parse{buffer: "\e" <> _}} = state) do
    ref = make_ref()
    Process.send_after(self(), {:esc_flush, ref}, @esc_ms)
    %{state | esc: ref}
  end

  defp arm_esc(state), do: %{state | esc: nil}

  defp enqueue(state, items) do
    {replies, events} = Enum.split_with(items, &match?({:reply, _, _}, &1))
    {colors, replies} = Enum.split_with(replies, &(elem(&1, 1) in [:fg, :bg, :palette, :scheme]))

    replies =
      Enum.reduce(replies, state.replies, fn {:reply, kind, data}, acc ->
        Logger.debug("tty reply #{kind}: #{inspect(data)}")
        Map.put(acc, kind, data)
      end)

    state = Enum.reduce(colors, %{state | replies: replies}, &color_reply/2)
    {events, state} = Enum.flat_map_reduce(events, state, &hit/2)
    drain(%{state | queue: state.queue ++ events})
  end

  # -- host colours ----------------------------------------------------------

  defp query_colors(state) do
    _ = Kernel.tty().write(state.tty, @color_queries)
    ref = make_ref()
    Process.send_after(self(), {:colors_done, ref}, @colors_ms)

    parse =
      case Guard.run_twice(Parse, :open_window, [state.parse, :colors, now() + @colors_ms]) do
        {:ok, p} -> p
        {:failed, _} -> state.parse
      end

    colors = %{fg: nil, bg: nil, palette: %{}, scheme: nil, n: 0, ref: ref}
    %{state | parse: parse, colors: colors}
  end

  # unsolicited (mode 2031) scheme report
  defp color_reply({:reply, :scheme, s}, %{colors: nil} = state),
    do: publish(%{state | caps: Map.put(state.caps || %{}, :scheme, s)}, %{scheme: s})

  defp color_reply({:reply, :scheme, s}, state), do: put_in(state.colors.scheme, s)
  defp color_reply(_late, %{colors: nil} = state), do: state

  defp color_reply({:reply, kind, v}, %{colors: c} = state) do
    c =
      case {kind, v} do
        {:palette, {n, rgb}} -> %{c | palette: Map.put(c.palette, n, rgb)}
        {k, rgb} -> Map.put(c, k, rgb)
      end

    state = %{state | colors: %{c | n: c.n + 1}}
    if c.n + 1 >= 258, do: colors_done(state), else: state
  end

  defp colors_done(%{colors: c} = state) do
    state = %{state | colors: nil}

    if c.fg || c.bg || c.scheme || c.palette != %{} do
      caps = %{colors: Map.take(c, [:fg, :bg, :palette]), scheme: c.scheme}
      publish(%{state | caps: caps}, caps)
    else
      state
    end
  end

  # caps to the session (when there is one), host colours to Render
  defp publish(state, nil), do: state

  defp publish(state, caps) do
    if is_pid(state.session), do: send(state.session, {:caps, caps})
    render = Client.whereis(state.id, :render)
    # Render's theme appearance (`Theme.Detect`) reads the merged caps
    if render && state.caps, do: send(render, {:caps, state.caps})

    with %{colors: c} <- caps,
         true <- render != nil,
         do: send(render, {:host_colors, Map.take(c, [:fg, :bg])})

    state
  end

  # mouse over chrome becomes `{:chrome, ...}`; a failing Hit passes the event unchanged
  defp hit({:mouse, _} = ev, %{hits: hits, grab: grab} = state) when hits != [] or grab != nil do
    case Guard.run_twice(Hit, :route, [hits, grab, ev, now()]) do
      {:ok, {events, grab}} -> {events, %{state | grab: grab}}
      {:failed, _} -> {[ev], state}
    end
  end

  defp hit(ev, state), do: {[ev], state}

  defp drain(%{session: s, inflight: nil, queue: [ev | rest]} = state) when is_pid(s) do
    state = %{state | queue: rest}

    case fast(ev, state.mode, fast_path(state)) do
      {m, f, a} ->
        # ponytail: a write that writes then raises is re-sent after a rollback
        Guard.run_twice(m, f, [ev | a], scan: false)
        drain(state)

      nil ->
        seq = state.seq + 1
        send(s, {:input, self(), seq, ev})
        %{state | seq: seq, inflight: {seq, ev}}
    end
  end

  defp drain(state), do: state

  # an inline client talks to a server over a socket: the in-VM fast path is not its own
  defp fast_path(%{inline: true}), do: nil
  defp fast_path(_state), do: :persistent_term.get(Protocol.fast_path_key(), nil)

  defp fast({:key, %{event: :release}}, _mode, _fast), do: nil

  defp fast(
         {:key, %{key: k, mods: m}},
         :terminal,
         %{passthrough: true, write: {_, _, _} = w, intercept: i}
       ),
       do: if(MapSet.member?(i, {k, m}), do: nil, else: w)

  defp fast(_ev, _mode, _fast), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
