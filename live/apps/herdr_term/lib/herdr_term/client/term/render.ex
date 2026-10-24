defmodule HerdrTerm.Client.Term.Render do
  @moduledoc """
  Attaches to the server endpoint (retrying every 50ms until it exists),
  hands the session to Input, keeps the scene and a per-pane rows cache, and
  blits paced frames.

  Option `transport` (`:ref`, default, or `:inline`) is sent in the attach.

  Rows (ref): `{:damage, id, _}` marks pane `id` dirty; a new scene marks dirty only
  panes that are new or whose `{:ref, id, layout_gen}` changed. Dirty panes are fetched
  through the attach reply's rows MFA (rows and cursor in one call) right before
  composing, so a burst of damage costs one fetch per frame and a keystroke one fetch.
  The host cursor is the focused pane's cached cursor placed in its rect.

  Rows (inline): non-empty `{:inline, rows}` in a scene replace the pane's cached rows,
  `{:inline, []}` keeps them, `{:rows, id, gen, rows}` updates them; the cursor is the
  scene's.

  Frames are at least `:min_frame_interval_ms` (default 6) apart with at most one
  pending timer. A frame repaints fully on the first frame, after a re-attach, when the
  scene size changes and on `:repaint` (`Tty.Owner` sends it when the tty resumes). A
  failing compose keeps the last frame and retries a full repaint every 500ms; a failing
  cursor keeps the last frame. `{:detached, reason}` goes to `Tty.Owner`.
  """

  use GenServer

  require Logger

  alias HerdrReload.Guard
  alias HerdrScene.Protocol
  alias HerdrScene.Scene
  alias HerdrTerm.{Client, Kernel}
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme
  alias HerdrTerm.Tty.Owner

  @retry_ms 50
  @retry_frame_ms 500
  # compose can hang on a bad edit; its result is a transient frame
  @compose [budget_ms: 50, scan: false]

  defstruct [
    :id,
    :endpoint,
    :tty,
    :session,
    :mon,
    :rows_mfa,
    :scene,
    :last_size,
    :timer,
    :notice,
    :theme,
    transport: :ref,
    rows: %{},
    cursors: %{},
    refs: %{},
    dirty: MapSet.new(),
    last_at: nil,
    repaint: true
  ]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Client.via(opts[:id], :render))

  @impl true
  def init(opts) do
    send(self(), :attach)

    {:ok,
     %__MODULE__{
       id: opts[:id],
       endpoint: Keyword.get(opts, :endpoint, Protocol.endpoint()),
       tty: Owner.tty(Client.via(opts[:id], :tty_owner)),
       theme: Theme.default(),
       transport: Keyword.get(opts, :transport, :ref)
     }}
  end

  @impl true
  def handle_cast({:input_up, pid}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if state.session, do: send(pid, {:session, state.session})
    {:noreply, state}
  end

  @impl true
  def handle_info(:attach, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, attach(state)}
  end

  def handle_info({:DOWN, mon, :process, _, _}, %{mon: mon} = state) do
    state = Map.merge(%__MODULE__{}, state)
    send_input(state, {:session, nil})
    # forget the refs: the next scene re-fetches every pane
    {:noreply, attach(%{state | session: nil, mon: nil, repaint: true, refs: %{}})}
  end

  def handle_info({:scene, %Scene{} = scene}, state) do
    state = Map.merge(%__MODULE__{}, state)
    ids = Enum.map(scene.panes, & &1.id)
    keep = MapSet.new(ids)
    init = {Map.take(state.rows, ids), MapSet.filter(state.dirty, &(&1 in keep)), %{}}

    {rows, dirty, refs} =
      Enum.reduce(scene.panes, init, fn
        %{rows: {:inline, []}}, acc ->
          acc

        %{id: id, rows: {:inline, r}}, {rows, dirty, refs} ->
          {Map.put(rows, id, Map.new(r)), dirty, refs}

        %{id: id, rows: {:ref, _, lg}}, {rows, dirty, refs} ->
          fresh? = Map.get(state.refs, id) == lg and Map.has_key?(rows, id)
          {rows, if(fresh?, do: dirty, else: MapSet.put(dirty, id)), Map.put(refs, id, lg)}
      end)

    cursors = Map.take(state.cursors, ids)
    state = %{state | scene: scene, rows: rows, dirty: dirty, refs: refs, cursors: cursors}
    {:noreply, schedule(state)}
  end

  def handle_info(:repaint, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, schedule(%{state | repaint: true})}
  end

  def handle_info({:damage, id, _gen}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, schedule(%{state | dirty: MapSet.put(state.dirty, id)})}
  end

  def handle_info({:rows, id, _gen, rows}, state) do
    state = Map.merge(%__MODULE__{}, state)
    old = Map.get(state.rows, id, %{})
    old = if is_map(old), do: old, else: Map.new(Enum.with_index(Tuple.to_list(old), &{&2, &1}))
    {:noreply, schedule(%{state | rows: Map.put(state.rows, id, Map.merge(old, Map.new(rows)))})}
  end

  def handle_info({:notice, notice}, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.info("notice: #{inspect(notice)}")
    {:noreply, %{state | notice: notice}}
  end

  # the server ended this client's session (protocol `{:detached, reason}`)
  def handle_info({:detached, _reason} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    if pid = Client.whereis(state.id, :tty_owner), do: send(pid, msg)
    {:noreply, state}
  end

  # a re-attached session's mirrored mode; Input reset its own on {:session, _} first
  def handle_info({:input_mode, _} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    send_input(state, msg)
    {:noreply, state}
  end

  def handle_info(:frame, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, render(%{state | timer: nil})}
  end

  def handle_info(msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.debug("render: ignored #{inspect(msg)}")
    {:noreply, state}
  end

  # attach

  defp attach(state) do
    case GenServer.whereis(state.endpoint) do
      nil -> retry(state)
      pid -> attach(state, pid)
    end
  end

  defp attach(state, endpoint) do
    # a pty that never got a window size reports 0x0
    {cols, rows, pw, ph} = Kernel.tty().size(state.tty)
    {cols, rows} = {max(cols, 1), max(rows, 1)}
    cell_px = if pw > 0 and ph > 0, do: {div(pw, cols), div(ph, rows)}

    req = %{
      kind: :term,
      transport: state.transport,
      size: %{cols: cols, rows: rows},
      cell_px: cell_px,
      caps: %{},
      client: self()
    }

    # Only exits: the endpoint can die or time out between whereis and the call, and
    # that is just "not attached yet" (retry). Raises and throws are bugs and crash this
    # process; this is not a Guard boundary.
    reply =
      try do
        GenServer.call(endpoint, {:attach, req})
      catch
        :exit, reason -> {:exit, reason}
      end

    with :ok <- Protocol.validate_attach_reply(reply), {:ok, session, %{rows: mfa}} <- reply do
      send_input(state, {:session, session})
      %{state | session: session, mon: Process.monitor(session), rows_mfa: mfa}
    else
      other ->
        Logger.warning("attach failed: #{inspect(other)}")
        retry(state)
    end
  end

  defp retry(state) do
    Process.send_after(self(), :attach, @retry_ms)
    state
  end

  defp send_input(state, msg) do
    if pid = Client.whereis(state.id, :input), do: send(pid, msg)
  end

  # pacing

  defp schedule(%{scene: nil} = state), do: state
  defp schedule(%{timer: t} = state) when t != nil, do: state

  defp schedule(state) do
    min = Application.get_env(:herdr_term, :min_frame_interval_ms, 6)
    since = if state.last_at, do: now() - state.last_at, else: min

    if since >= min,
      do: render(state),
      else: %{state | timer: Process.send_after(self(), :frame, min - since)}
  end

  # frame

  defp render(%{scene: nil} = state), do: state

  defp render(state) do
    state = Enum.reduce(state.dirty, %{state | dirty: MapSet.new()}, &fetch(&2, &1))
    scene = state.scene
    args = [scene, state.rows, state.cursors, state.theme]

    case Guard.run_twice(Compose, :screen, args, @compose) do
      {:ok, {frame, cursor}} ->
        repaint = state.repaint or scene.size != state.last_size
        {at, shape} = cursor || {nil, :block}
        opts = %{cursor: at, shape: shape, repaint: repaint}

        with {:error, why} <- Kernel.blit().frame(state.tty, frame, opts),
             do: Logger.warning("frame refused: #{inspect(why)}")

        %{state | repaint: false, last_size: scene.size, last_at: now()}

      # The screen still shows the frame before: retry in full, not at the next damage.
      # ponytail: fixed 500ms retry while Compose keeps failing (one error log each)
      {:failed, _} ->
        %{state | repaint: true, timer: Process.send_after(self(), :frame, @retry_frame_ms)}
    end
  end

  defp fetch(%{rows_mfa: nil} = state, _id), do: state

  defp fetch(%{rows_mfa: {m, f, a}} = state, id) do
    case Guard.run_twice(m, f, [id | a], scan: false) do
      {:ok, {_gen, tuple, cursor}} ->
        %{
          state
          | rows: Map.put(state.rows, id, tuple),
            cursors: Map.put(state.cursors, id, cursor)
        }

      _ ->
        state
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
