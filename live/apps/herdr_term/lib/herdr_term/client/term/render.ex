defmodule HerdrTerm.Client.Term.Render do
  @moduledoc """
  Attaches to the server endpoint (retrying every 50ms until it exists),
  hands the session to Input, keeps the scene and a per-pane rows cache, and
  blits paced frames.

  Rows: `{:damage, id, _}` marks pane `id` dirty and a new scene marks every
  ref pane dirty; dirty panes are fetched through the attach reply's rows MFA
  right before composing, so a burst of damage costs one fetch per frame.
  Inline rows (`{:inline, rows}` panes, `{:rows, id, gen, rows}`) seed the same
  cache. Frames are at least `:min_frame_interval_ms` (default 6) apart with at
  most one pending timer. A frame repaints fully on the first frame, after a
  re-attach, and when the scene size changes.
  """

  use GenServer

  require Logger

  alias HerdrScene.Protocol
  alias HerdrScene.Scene
  alias HerdrTerm.{Client, Kernel, SafeApply}
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme
  alias HerdrTerm.Tty.Owner

  @retry_ms 50

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
    rows: %{},
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
       theme: Theme.default()
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
    {:noreply, attach(%{state | session: nil, mon: nil, repaint: true})}
  end

  def handle_info({:scene, %Scene{} = scene}, state) do
    state = Map.merge(%__MODULE__{}, state)
    ids = MapSet.new(scene.panes, & &1.id)

    {rows, dirty} =
      Enum.reduce(scene.panes, {Map.take(state.rows, MapSet.to_list(ids)), MapSet.new()}, fn
        %{id: id, rows: {:inline, r}}, {rows, dirty} -> {Map.put(rows, id, Map.new(r)), dirty}
        %{id: id}, {rows, dirty} -> {rows, MapSet.put(dirty, id)}
      end)

    {:noreply, schedule(%{state | scene: scene, rows: rows, dirty: dirty})}
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
    {cols, rows, pw, ph} = Kernel.tty().size(state.tty)
    cell_px = if pw > 0 and ph > 0, do: {div(pw, cols), div(ph, rows)}

    req = %{
      kind: :term,
      transport: :ref,
      size: %{cols: cols, rows: rows},
      cell_px: cell_px,
      caps: %{},
      client: self()
    }

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
    rows = Enum.reduce(state.dirty, state.rows, &fetch(&2, &1, state.rows_mfa))
    state = %{state | rows: rows, dirty: MapSet.new()}
    scene = state.scene

    case SafeApply.run(Compose, :frame, [scene, rows, state.theme]) do
      {:ok, frame} ->
        repaint = state.repaint or scene.size != state.last_size
        shape = Compose.cursor_shape(scene) || :block
        opts = %{cursor: Compose.cursor(scene), shape: shape, repaint: repaint}
        Kernel.blit().frame(state.tty, frame, opts)
        %{state | repaint: false, last_size: scene.size, last_at: now()}

      {:failed, _} ->
        state
    end
  end

  defp fetch(rows, _id, nil), do: rows

  defp fetch(rows, id, {m, f, a}) do
    case SafeApply.run(m, f, [id | a]) do
      {:ok, {_gen, tuple}} -> Map.put(rows, id, tuple)
      _ -> rows
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
