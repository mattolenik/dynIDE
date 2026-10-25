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

  Chrome: the layout (`Render.Chrome.layout/3`, guarded) is cached and recomputed only
  when the scene's chrome or size or the theme changed; a failing layout keeps the old
  one and is re-attempted every 500ms until it succeeds (then a full repaint). When its hits change they go to Input as `{:chrome_hits, hits}`.

  Rows (inline): the rows listed in a scene's `{:inline, rows}` replace those rows of the
  pane's cache and unlisted rows keep it (`{:inline, []}` changes nothing);
  `{:rows, id, gen, rows}` merges the same way; the cursor is the scene's.

  Frames are at least `:min_frame_interval_ms` (default 6) apart with at most one
  pending timer. A frame repaints fully on the first frame, after a re-attach, when the
  scene size changes and on `:repaint` (`Tty.Owner` sends it when the tty resumes). A
  failing compose keeps the last frame and retries a full repaint every 500ms; a failing
  cursor keeps the last frame.

  Alerts: `{:alert, a}` runs `Alert.actions/2` over the root props: OSC 9 through the
  tty; a sound runs this client's own sound command (`sound_command/0`) with the sound
  name as its last argument (a port, fire and forget; a missing command logs once), else
  writes BEL. The command is never taken from the scene: a remote client must not run a
  command it received over the wire.

  `{:detached, reason}` and
  `{:handoff, map}` go to `Tty.Owner`.
  """

  use GenServer

  require Logger

  alias HerdrReload.Guard
  alias HerdrScene.Protocol
  alias HerdrScene.Scene
  alias HerdrTerm.{Client, Kernel}
  alias HerdrTerm.Client.Term.Alert
  alias HerdrTerm.Client.Term.Render.{Chrome, Compose}
  alias HerdrTerm.Client.Term.Theme
  alias HerdrTerm.Client.Term.Theme.Detect
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
    :theme_key,
    :colorfgbg,
    :chrome_key,
    :chrome_retry,
    :sound_warned,
    transport: :ref,
    caps: nil,
    appearance: :dark,
    chrome: %{base: %{}, top: %{}, hits: [], dim: false},
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
    colorfgbg = System.get_env("COLORFGBG")

    {:ok,
     %__MODULE__{
       id: opts[:id],
       endpoint: Keyword.get(opts, :endpoint, Protocol.endpoint()),
       tty: Owner.tty(Client.via(opts[:id], :tty_owner)),
       theme: Theme.default(),
       colorfgbg: colorfgbg,
       appearance: Detect.appearance(nil, colorfgbg),
       transport: Keyword.get(opts, :transport, :ref)
     }}
  end

  @impl true
  def handle_cast({:input_up, pid}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if state.session, do: send(pid, {:session, state.session})
    if state.chrome.hits != [], do: send(pid, {:chrome_hits, state.chrome.hits})
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
          {Map.put(rows, id, Map.merge(as_map(Map.get(rows, id, %{})), Map.new(r))), dirty, refs}

        %{id: id, rows: {:ref, _, lg}}, {rows, dirty, refs} ->
          fresh? = Map.get(state.refs, id) == lg and Map.has_key?(rows, id)
          {rows, if(fresh?, do: dirty, else: MapSet.put(dirty, id)), Map.put(refs, id, lg)}
      end)

    cursors = Map.take(state.cursors, ids)
    state = %{state | scene: scene, rows: rows, dirty: dirty, refs: refs, cursors: cursors}
    {:noreply, state |> refresh_theme() |> chrome() |> schedule()}
  end

  # the client's host caps (protocol shape): scheme, else background luminance
  def handle_info({:caps, caps}, state) do
    state = Map.merge(%__MODULE__{}, state)
    appearance = Detect.appearance(caps, state.colorfgbg)
    state = refresh_theme(%{state | caps: caps, appearance: appearance})
    {:noreply, state |> chrome() |> schedule()}
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
    old = as_map(Map.get(state.rows, id, %{}))
    {:noreply, schedule(%{state | rows: Map.put(state.rows, id, Map.merge(old, Map.new(rows)))})}
  end

  def handle_info({:notice, notice}, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.info("notice: #{inspect(notice)}")
    {:noreply, %{state | notice: notice}}
  end

  # the server ended this client's session (protocol `{:detached, reason}`), or a handoff
  def handle_info({tag, _} = msg, state) when tag in [:detached, :handoff] do
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

  # a protocol alert: OSC 9, BEL or the sound command, per the scene root's props
  def handle_info({:alert, a}, state) do
    state = Map.merge(%__MODULE__{}, state)
    props = (state.scene && state.scene.chrome && state.scene.chrome.props) || %{}

    case Guard.run_twice(Alert, :actions, [a, props], scan: false) do
      {:ok, actions} -> {:noreply, Enum.reduce(actions, state, &perform(&2, &1, props))}
      {:failed, _} -> {:noreply, state}
    end
  end

  # a sound command's output or exit (its port is closed by then): nothing to do
  def handle_info({port, _}, state) when is_port(port),
    do: {:noreply, Map.merge(%__MODULE__{}, state)}

  def handle_info(:chrome_retry, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | chrome_retry: nil, repaint: true} |> chrome() |> schedule()}
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

  # alerts

  defp perform(state, {:osc9, text}, _props), do: tty_write(state, ["\e]9;", text, "\a"])

  defp perform(state, {:sound, name}, _props) do
    case sound_command() do
      nil -> tty_write(state, "\a")
      cmd -> play(state, cmd, name)
    end
  end

  defp perform(state, _other, _props), do: state

  @doc """
  The client-local sound command: app env `:herdr_term, :sound_command`, else
  `$HERDR_LIVE_SOUND_COMMAND`; nil (BEL) when neither is set.
  """
  @spec sound_command() :: binary | nil
  def sound_command do
    case Application.get_env(:herdr_term, :sound_command) ||
           System.get_env("HERDR_LIVE_SOUND_COMMAND") do
      "" -> nil
      cmd -> cmd
    end
  end

  defp tty_write(state, data) do
    _ = Kernel.tty().write(state.tty, data)
    state
  end

  # fire and forget; output is discarded with the port's messages
  defp play(state, cmd, name) do
    case System.find_executable(cmd) do
      nil ->
        missing(state, cmd)

      exe ->
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [name]
        ])

        state
    end
  rescue
    _ in ErlangError -> missing(state, cmd)
  end

  defp missing(%{sound_warned: cmd} = state, cmd), do: state

  defp missing(state, cmd) do
    Logger.warning("sound command #{inspect(cmd)} not found or not executable")
    %{state | sound_warned: cmd}
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

  # The theme follows the root theme props and the appearance; recomputed only when
  # either changes, so the chrome layout key (which holds the theme) stays stable.
  defp refresh_theme(%{scene: nil} = state), do: state

  defp refresh_theme(%{scene: scene, appearance: appearance} = state) do
    props = scene.chrome && scene.chrome.props[:theme]
    key = {props, appearance}

    if key == state.theme_key,
      do: state,
      else: %{
        state
        | theme: Theme.for_scene(props, appearance),
          theme_key: key,
          repaint: true
      }
  end

  # chrome layout, once per chrome/size/theme change

  # An equal key is stored anyway: it holds the scene's own terms, so later per-frame
  # compares are pointer-equal instead of deep.
  defp chrome(%{scene: nil} = state), do: state

  defp chrome(%{scene: scene, theme: theme} = state) do
    key = {scene.chrome, scene.size, theme}

    cond do
      key == state.chrome_key -> %{state | chrome_key: key}
      state.chrome_retry -> state
      true -> relayout(state, key)
    end
  end

  # A failing layout (logged by the Guard) keeps the old layout and key; it is
  # re-attempted by `:chrome_retry` after @retry_frame_ms (one failure log each).
  defp relayout(state, {chrome, size, theme} = key) do
    case Guard.run_twice(Chrome, :layout, [chrome, size, theme], @compose) do
      {:ok, layout} ->
        if layout.hits != state.chrome.hits, do: send_input(state, {:chrome_hits, layout.hits})
        %{state | chrome: layout, chrome_key: key}

      {:failed, _} ->
        %{state | chrome_retry: Process.send_after(self(), :chrome_retry, @retry_frame_ms)}
    end
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
    # a no-op unless the theme changed since the scene (the key compare is a pointer check)
    state = chrome(state)
    scene = state.scene
    args = [scene, state.rows, state.cursors, state.theme, state.chrome]

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

  # a cached value is a map, or the tuple a `{:ref}` fetch returned
  defp as_map(rows) when is_map(rows), do: rows
  defp as_map(rows), do: Map.new(Enum.with_index(Tuple.to_list(rows), &{&2, &1}))
end
