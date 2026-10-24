defmodule HerdrServer.App.Store do
  @moduledoc """
  Holds the app state. Thin: every change goes through `App.Actions` via `SafeApply`, and
  this module only interprets the resulting effects.

    * `event/2` (call, from a `Client.Session`): `size` is the calling client's size; a
      client whose size differs from the current driver first resizes the app (contract
      decision 4, latest active client drives). The app is initialised lazily by the
      first event, at the first client's size.
    * `event_async/1` (cast) is for processes the Store calls into (`Pane.Server`).
    * Subscribers get `{:app_changed, app}` after each event that changed the app. The
      Store only ever `send`s to sessions, so there is no call cycle.
    * After each event: panes of inactive tabs are hidden, active-tab panes are resized to
      their content rects (bumping `layout_gen`), and the fast-path term is republished if
      its value changed.
  """
  use GenServer

  require Logger

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Keybinds}
  alias HerdrServer.{Kernel, Layout, SafeApply}
  alias HerdrServer.Pane.{Input, Rows, Server}
  alias HerdrServer.Pane.Supervisor, as: Panes

  defstruct app: nil, subs: %{}, driver: nil, sizes: %{}, hidden: MapSet.new(), fast: nil

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec event(tuple, %{cols: pos_integer, rows: pos_integer} | nil) :: :ok
  def event(event, size), do: GenServer.call(__MODULE__, {:event, event, size})

  @spec event_async(tuple) :: :ok
  def event_async(event), do: GenServer.cast(__MODULE__, {:event, event})

  @spec snapshot() :: Actions.app() | nil
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec subscribe(pid) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Test helper: closes every pane and forgets the app; the next event re-initialises."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:event, ev, size}, {origin, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, handle_event(state, ev, size, origin)}
  end

  def handle_call(:snapshot, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.app, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    subs = Map.put_new_lazy(state.subs, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subs: subs}}
  end

  def handle_call(:reset, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    Enum.each(Kernel.keeper().pane_ids(), &close/1)
    :persistent_term.erase(Protocol.fast_path_key())
    {:reply, :ok, %__MODULE__{subs: state.subs}}
  end

  @impl true
  def handle_cast({:event, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, handle_event(state, ev, nil, nil)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
  end

  def handle_info(_other, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  # --- events ---

  # A failed batch (driver resize + event) is discarded whole; init commits on its own.
  defp handle_event(state, ev, size, origin) do
    old = state.app
    state = if old == nil, do: commit(state, [{:init, first_size(ev, size)}], origin), else: state

    state =
      if state.app == nil,
        do: state,
        else: commit(state, batch(state, ev, size), origin, &%{&1 | driver: size || &1.driver})

    state = state |> settle() |> publish_fast()
    if state.app != old, do: Enum.each(Map.keys(state.subs), &send(&1, {:app_changed, state.app}))
    state
  end

  defp batch(state, ev, size) do
    drive =
      if size != nil and size != state.driver and not match?({:resize, _}, ev),
        do: [{:resize, Map.put(size, :cell_px, nil)}],
        else: []

    drive ++ [ev]
  end

  defp first_size({:resize, %{cols: c, rows: r}}, _), do: %{cols: c, rows: r}
  defp first_size(_, size), do: size || %{cols: 80, rows: 24}

  defp commit(state, steps, origin, after_ok \\ & &1) do
    case Enum.reduce_while(steps, {:ok, state}, &step(elem(&2, 1), &1, origin)) do
      {:ok, new} -> after_ok.(new)
      :failed -> state
    end
  end

  defp step(state, step, origin) do
    result =
      case step do
        {:init, size} -> SafeApply.run(Actions, :init, [size])
        ev -> SafeApply.run(Actions, :apply, [state.app, ev])
      end

    case result do
      {:ok, {app, effects}} ->
        {:cont, {:ok, Enum.reduce(effects, %{state | app: app}, &effect(&2, &1, origin))}}

      {:failed, reason} ->
        notice(origin, %{level: :error, text: "action failed: #{inspect(reason)}"})
        {:halt, :failed}
    end
  end

  defp effect(state, {:spawn, id, %{cols: c, rows: r}}, _origin) do
    opts = %{
      cmd: System.get_env("SHELL", "/bin/sh"),
      args: [],
      env: [],
      cwd: File.cwd!(),
      cols: c,
      rows: r
    }

    with {:ok, _} <- Kernel.keeper().open(id, opts),
         {:ok, _} <- Panes.start_pane(id) do
      put_in(state.sizes[id], {c, r})
    else
      err ->
        Logger.error("spawning pane #{id} failed: #{inspect(err)}")
        state
    end
  end

  defp effect(state, {:close, id}, _origin) do
    close(id)
    %{state | sizes: Map.delete(state.sizes, id), hidden: MapSet.delete(state.hidden, id)}
  end

  defp effect(state, other, origin) do
    io(other, origin)
    state
  end

  defp io({:key, id, ev}, _), do: Input.key(ev, id)
  defp io({:mouse, id, ev}, _), do: Input.mouse(ev, id)
  defp io({:paste, id, bin}, _), do: Input.paste(bin, id)
  defp io({:focus_report, id, f}, _), do: Input.focus(f, id)
  defp io({:notice, n}, origin), do: notice(origin, n)
  defp io({:detach}, origin), do: notice(origin, %{level: :info, text: "detach not implemented"})
  defp io(other, _), do: Logger.warning("unknown effect #{inspect(other)}")

  # idempotent: closing an already-gone pane is a no-op everywhere
  defp close(id) do
    Panes.stop_pane(id)
    Kernel.keeper().close(id)
    Rows.delete(id)
  end

  defp notice(origin, n) when is_pid(origin), do: send(origin, {:notice, n})
  defp notice(_origin, n), do: Logger.info("notice: #{inspect(n)}")

  # --- after every event ---

  defp settle(%{app: nil} = state), do: state

  defp settle(%{app: %{session: s}} = state) do
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    rects = tab.layout |> Layout.panes(s.area) |> Layout.borders(s.area)
    visible = MapSet.new(rects, & &1.id)

    state =
      Enum.reduce(Map.keys(s.panes), state, &hide(&2, &1, not MapSet.member?(visible, &1)))

    Enum.reduce(rects, state, &resize/2)
  end

  defp hide(state, id, hidden?) do
    if MapSet.member?(state.hidden, id) == hidden? do
      state
    else
      Server.set_hidden(id, hidden?)
      op = if hidden?, do: &MapSet.put/2, else: &MapSet.delete/2
      %{state | hidden: op.(state.hidden, id)}
    end
  end

  defp resize(%{id: id, rect: %{w: w, h: h}}, state) do
    case state.sizes do
      %{^id => old} when old != {w, h} and w > 0 and h > 0 ->
        Server.resize(id, w, h)
        state = put_in(state.sizes[id], {w, h})
        update_in(state.app.session.panes[id].layout_gen, &(&1 + 1))

      _ ->
        state
    end
  end

  defp publish_fast(%{app: nil} = state), do: state

  defp publish_fast(%{app: %{focus: f, ui: ui}} = state) do
    fast = %{
      pane: f.pane,
      write: f.pane && {Input, :key, [f.pane]},
      intercept: Keybinds.intercept_set(ui.keybinds),
      passthrough: f.mode == :terminal and f.modal == []
    }

    old = state.fast

    if old && Map.delete(old, :gen) == fast do
      state
    else
      fast = Map.put(fast, :gen, if(old, do: old.gen + 1, else: 1))
      :persistent_term.put(Protocol.fast_path_key(), fast)
      %{state | fast: fast}
    end
  end
end
