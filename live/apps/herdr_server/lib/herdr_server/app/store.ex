defmodule HerdrServer.App.Store do
  @moduledoc """
  Holds the app state. Thin: every change goes through `App.Actions` via `SafeApply`, and
  this module only interprets the resulting effects.

    * `event/2` (call, from a `Client.Session`): `size` is the calling client's size
      (`%{cols, rows, cell_px}`); a client whose size differs from the current driver
      first resizes the app (contract decision 4, latest active client drives). The app is
      initialised lazily by the first event, at the first client's size.
    * The Store remembers each session's last size. When the driving session goes down,
      the latest active remaining session drives and pane sizes are re-settled at its size.
    * `event_async/1` (cast) is for processes the Store calls into (`Pane.Server`).
    * Subscribers get `{:app_changed, app}` after each event that changed the app. The
      Store only ever `send`s to sessions, so there is no call cycle.
    * After each event: panes of inactive tabs are hidden, active-tab panes are resized to
      their content rects (bumping `layout_gen`), and the fast-path term is republished if
      its value changed. It carries no input mode: modes are per client.
    * A spawn that fails (keeper open or pane server start) sends the origin a warning
      notice and closes the pane again, as `{:pane_exited, id}`.
    * A Store restart starts from an empty app: `init/1` closes every pane the keeper
      still holds (and its `Pane.Server`), and live sessions stop on the Store's `:DOWN`
      so their clients re-attach. Adopting the surviving panes instead is M4's ETS-mirror
      job.
  """
  use GenServer

  require Logger

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Keybinds}
  alias HerdrServer.{Kernel, Layout, SafeApply}
  alias HerdrServer.Pane.{Input, Rows, Server}
  alias HerdrServer.Pane.Supervisor, as: Panes

  # bytes of scrollback per pane
  @max_scrollback 10_000_000

  defstruct app: nil,
            subs: %{},
            driver: nil,
            driver_pid: nil,
            clients: %{},
            sizes: %{},
            hidden: MapSet.new(),
            fast: nil

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec event(
          tuple,
          %{
            required(:cols) => pos_integer,
            required(:rows) => pos_integer,
            optional(:cell_px) => {pos_integer, pos_integer} | nil
          }
          | nil
        ) :: :ok
  def event(event, size), do: GenServer.call(__MODULE__, {:event, event, size})

  @doc """
  Applies a keybind action `{m, f, a}` (resolved by the calling session's `Client.Keys`)
  as `apply(m, f, [app | a])`, through `SafeApply` and the same effect handling and
  driver rule as `event/2`.
  """
  @spec run(Keybinds.mfa_t(), map | nil) :: :ok
  def run({m, f, a} = mfa, size) when is_atom(m) and is_atom(f) and is_list(a),
    do: GenServer.call(__MODULE__, {:event, {:run, mfa}, size})

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
  def init(:ok) do
    # a restarted Store forgets the app: close what the previous incarnation left open
    close_all()
    :persistent_term.erase(Protocol.fast_path_key())
    {:ok, %__MODULE__{}}
  end

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
    close_all()
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
    {:noreply, handoff(%{state | subs: Map.delete(state.subs, pid)}, pid)}
  end

  def handle_info(_other, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  # --- events ---

  # A failed batch (driver resize + event) is discarded whole; init commits on its own.
  defp handle_event(state, ev, size, origin) do
    state = seen(state, size, origin)
    old = state.app
    state = if old == nil, do: commit(state, [{:init, first_size(ev, size)}], origin), else: state

    state =
      if state.app == nil,
        do: state,
        else: commit(state, batch(state, ev, size), origin, &drive(&1, size, origin))

    state = state |> settle() |> publish_fast()
    if state.app != old, do: Enum.each(Map.keys(state.subs), &send(&1, {:app_changed, state.app}))
    state
  end

  defp batch(state, ev, size) do
    drive =
      if size != nil and size != state.driver and not match?({:resize, _}, ev),
        do: [{:resize, Map.put_new(size, :cell_px, nil)}],
        else: []

    drive ++ [ev]
  end

  defp drive(state, nil, _origin), do: state
  defp drive(state, size, origin), do: %{state | driver: size, driver_pid: origin}

  defp seen(state, size, origin) when is_pid(origin) and size != nil do
    at = System.unique_integer([:monotonic])
    %{state | clients: Map.put(state.clients, origin, %{size: size, at: at})}
  end

  defp seen(state, _size, _origin), do: state

  # the driving session left: the latest active remaining one drives (re-settles sizes)
  defp handoff(state, pid) do
    state = %{state | clients: Map.delete(state.clients, pid)}

    if pid == state.driver_pid and state.app != nil and state.clients != %{} do
      {next, %{size: size}} = Enum.max_by(state.clients, fn {_, c} -> c.at end)

      handle_event(
        %{state | driver_pid: nil},
        {:resize, Map.put_new(size, :cell_px, nil)},
        size,
        next
      )
    else
      state
    end
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
        {:run, {m, f, a}} -> SafeApply.run(m, f, [state.app | a])
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

  defp effect(state, {:spawn, id, %{cols: c, rows: r}}, origin) do
    # The kernel sets TERM=xterm-256color; Pane.Server subscribes when it starts. Children
    # inherit the OS environment of the VM, not `System.put_env/2` changes: extra
    # variables go in `config :herdr_server, :pane_env` (a list of {name, value}).
    spec = %{
      cmd: System.get_env("SHELL", "/bin/sh"),
      args: [],
      env: Application.get_env(:herdr_server, :pane_env, []),
      cwd: File.cwd!(),
      cols: c,
      rows: r,
      max_scrollback: @max_scrollback,
      subscriber: nil
    }

    with {:ok, kid} <- Kernel.keeper().open(spec),
         :ok <- Rows.put_kernel_id(id, kid),
         {:ok, _} <- Panes.start_pane(id) do
      put_in(state.sizes[id], {c, r})
    else
      err ->
        Logger.error("spawning pane #{id} failed: #{inspect(err)}")
        notice(origin, %{level: :warning, text: "could not start pane #{id}: #{inspect(err)}"})
        # after this event: drops the pane from the layout and closes whatever was opened
        event_async({:pane_exited, id})
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

  defp io({:paste, id, bin}, origin) do
    with {:error, {:truncated, n}} <- Input.paste(bin, id),
         do: notice(origin, %{level: :warning, text: "paste truncated after #{n} bytes"})
  end

  defp io({:focus_report, id, f}, _), do: Input.focus(f, id)
  defp io({:notice, n}, origin), do: notice(origin, n)
  # the originating session tells its client {:detached, :requested} and stops
  defp io({:detach}, origin) when is_pid(origin), do: send(origin, {:detach})
  defp io({:detach}, _origin), do: :ok
  defp io(other, _), do: Logger.warning("unknown effect #{inspect(other)}")

  # idempotent: closing an already-gone pane is a no-op everywhere
  defp close(id) do
    Panes.stop_pane(id)
    kid = Rows.kernel_id(id)
    if kid, do: Kernel.keeper().close(kid)
    Rows.delete(id)
  end

  # every pane this Store mapped, then anything else the keeper still holds
  defp close_all do
    Enum.each(Rows.kernel_ids(), fn {id, _kid} -> close(id) end)
    keeper = Kernel.keeper()
    Enum.each(keeper.ids(), &keeper.close/1)
  end

  defp notice(origin, n) when is_pid(origin), do: send(origin, {:notice, n})
  defp notice(_origin, n), do: Logger.info("notice: #{inspect(n)}")

  # --- after every event ---

  defp settle(%{app: nil} = state), do: state

  # a failing Layout keeps the previous pane sizes and visibility
  defp settle(%{app: %{session: s}} = state) do
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))

    with {:ok, panes} <- SafeApply.run(Layout, :panes, [tab.layout, s.area]),
         {:ok, rects} <- SafeApply.run(Layout, :borders, [panes, s.area]) do
      visible = MapSet.new(rects, & &1.id)

      state =
        Enum.reduce(Map.keys(s.panes), state, &hide(&2, &1, not MapSet.member?(visible, &1)))

      Enum.reduce(rects, state, &resize/2)
    else
      {:failed, _} -> state
    end
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
        Server.resize(id, w, h, state.driver && Map.get(state.driver, :cell_px))
        state = put_in(state.sizes[id], {w, h})
        update_in(state.app.session.panes[id].layout_gen, &(&1 + 1))

      _ ->
        state
    end
  end

  defp publish_fast(%{app: nil} = state), do: state

  defp publish_fast(%{app: %{focus: f, ui: ui}} = state) do
    case SafeApply.run(Keybinds, :intercept_set, [ui.keybinds]) do
      {:ok, intercept} -> publish_fast(state, f, intercept)
      # keeps the previous fast path
      {:failed, _} -> state
    end
  end

  defp publish_fast(state, f, intercept) do
    fast = %{
      pane: f.pane,
      write: f.pane && {Input, :key, [f.pane]},
      intercept: intercept,
      # shared state only; each client also checks its own input mode
      passthrough: f.pane != nil and f.modal == []
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
