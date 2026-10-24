defmodule HerdrServer.App.Store do
  @moduledoc """
  Holds the app state. Thin: every change goes through `App.Actions` via `HerdrReload.Guard`, and
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
    * `app.session`, `app.focus`, `app.ui` and the bookkeeping are mirrored to
      `HerdrServer.Mirror`, debounced (`Store.Mirror`). A restarted Store reconciles the
      mirrored app with the keeper (`App.Reconcile`: panes whose kernel is gone are dropped,
      live mapped panes the mirror lost, e.g. spawned within the debounce window, are
      adopted into a "scratch" tab; missing `Pane.Server`s restarted), re-monitors the
      mirrored sessions and republishes the fast path; sessions re-subscribe and push full
      scenes. Only an empty mirror (or a failing reconcile) starts fresh, closing whatever
      the keeper still holds.
    * A repeat failure of `Actions.apply` (the guard rolled back batch K and the old code
      failed on the same event too) restores the `state_at_load` of the reload server's
      `last_rolled_back/1` batch when it is K or older, reconciled with the keeper as
      above (`Store.Mirror.keep_monotonic/2`), and warns every subscriber (an origin that is
      not one, such as an API request, gets the error notice). Without such a
      state, or on an unattributed failure, the event is discarded with an error notice.
      The reload server is `config :herdr_server, :reload_server` (default
      `HerdrReload.Server`).
    * Handoff (M5): the latest app is held with the broker and a new VM's `init/1` adopts
      it before looking at the mirror (`Store.Carry`). The adopted app is mirrored at once,
      so a later Store restart in this VM restarts from the mirror as above.
    * Persistence (M8): a fresh Store (no carry, no mirrored app: `Mirror.app()` nil) with
      persistence enabled restores the app last written to disk (`Persist.Load`) in
      `handle_continue/2`, spawning each pane's `$SHELL` in its recorded cwd (retried once
      in the Store's cwd if that open fails) over its saved scrollback. The
      precedence is carry > mirror > disk: a carried or mirrored app never reads the disk.
      Without a usable file the app stays nil and the first event initialises it.
    * In a VM that adopted panes (`Link.adopt_reason/0` not nil) no restart or restore
      closes a keeper pane nothing maps (`App.Restore`): it may be an adopted child.
  """
  use GenServer

  require Logger

  alias HerdrReload.Guard
  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Keybinds, Reconcile, Restore, Upgrade}
  alias HerdrServer.App.Store.{Carry, Mirror}
  alias HerdrServer.Handoff.Link
  alias HerdrServer.{Kernel, Layout}
  alias HerdrServer.Pane.{Input, Rows, Server}
  alias HerdrServer.Pane.Supervisor, as: Panes
  alias HerdrServer.Persist.{Disk, Load}

  # bytes of scrollback per pane
  @max_scrollback 10_000_000

  defstruct app: nil,
            subs: %{},
            driver: nil,
            driver_pid: nil,
            clients: %{},
            sizes: %{},
            hidden: MapSet.new(),
            fast: nil,
            hold_timer: nil,
            mirrored: %{},
            flush: nil

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
  as `apply(m, f, [app | a])`, through `HerdrReload.Guard` and the same effect handling and
  driver rule as `event/2`.
  """
  @spec run(Keybinds.mfa_t(), map | nil) :: :ok
  def run({m, f, a} = mfa, size) when is_atom(m) and is_atom(f) and is_list(a),
    do: GenServer.call(__MODULE__, {:event, {:run, mfa}, size})

  @doc """
  Runs `{m, f, a}` like `run/2` with no size, and replies `{:ok, before, after}` (the app
  before is nil before the first init). Notices for the caller arrive as `{:notice, map}`
  messages ahead of the reply.
  """
  @spec request(Keybinds.mfa_t()) :: {:ok, Actions.app() | nil, Actions.app()}
  def request({m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a),
    do: GenServer.call(__MODULE__, {:request, mfa})

  @spec event_async(tuple) :: :ok
  def event_async(event), do: GenServer.cast(__MODULE__, {:event, event})

  @spec snapshot() :: Actions.app() | nil
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec subscribe(pid) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "Stops sending `pid` `{:app_changed, app}` (a no-op for a non-subscriber)."
  @spec unsubscribe(pid) :: :ok
  def unsubscribe(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

  @doc "Test helper: closes every pane and forgets the app; the next event re-initialises."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Holds the latest app with the broker now if a coalesced HOLD is pending."
  @spec flush_hold() :: :ok
  def flush_hold do
    GenServer.call(__MODULE__, :flush_hold, 5000)
  catch
    # a Store restarting into its init (which calls the Link) must not block the Link
    :exit, {reason, _} when reason in [:noproc, :timeout] ->
      Logger.warning("app/store flush skipped: #{inspect(reason)}")
      :ok
  end

  @impl true
  def init(:ok) do
    case Link.take_adopted(Carry.key()) do
      [{_key, blob, _fds}] ->
        :persistent_term.erase(Protocol.fast_path_key())
        {:ok, adopt_carried(blob)}

      [] ->
        init_local()
    end
  end

  defp init_local do
    case HerdrServer.Mirror.app() do
      nil ->
        # a fresh start: close what a previous incarnation without a mirror left open
        lost(Restore.close_all(), :fresh_restart)
        :persistent_term.erase(Protocol.fast_path_key())
        cfg = Disk.config()

        # a Store that crashed restoring this file must not read it again
        if cfg.enabled and not Load.crashed?(cfg),
          do: {:ok, %__MODULE__{}, {:continue, {:disk, cfg}}},
          else: {:ok, %__MODULE__{}}

      app ->
        # a mirrored app in this VM means the Store itself restarted
        HerdrReload.Telemetry.event(:crash, proc: :store, reason: :restart, action: :restored)
        {:ok, adopt(app)}
    end
  end

  defp adopt(app) do
    state = struct(%__MODULE__{}, Mirror.read_book())
    subs = Map.new(state.clients, fn {pid, _} -> {pid, Process.monitor(pid)} end)
    fast = :persistent_term.get(Protocol.fast_path_key(), nil)
    state = %{state | subs: subs, fast: fast}

    case reconcile(state, app) do
      {:ok, state} ->
        ids = Map.keys(state.app.session.panes)
        Enum.each(ids, &Restore.ensure_server/1)
        # settle only acts where it disagrees: start from what the pane servers hold
        hidden =
          for id <- ids,
              match?(%{hidden: true}, HerdrServer.Mirror.pane(id)),
              into: MapSet.new(),
              do: id

        Mirror.dirty(%{state | hidden: hidden}) |> settle() |> publish_fast()

      :failed ->
        lost(Restore.close_all(), :reconcile_failed)
        :persistent_term.erase(Protocol.fast_path_key())
        %__MODULE__{subs: subs}
    end
  end

  # mirrored and rolled-back apps may predate the current structs: upgraded first
  defp reconcile(state, app) do
    g = [server: reload_server()]

    with {:ok, app} <- Guard.run_twice(Upgrade, :app, [app], g),
         {:ok, {app, effects}} <- Guard.run_twice(Reconcile, :run, [app, Restore.live()], g) do
      {:ok, Enum.reduce(effects, %{state | app: app}, &effect(&2, &1, nil))}
    else
      {:failed, _} -> :failed
    end
  end

  @impl true
  def handle_continue({:disk, cfg}, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = Load.run(state, cfg, &effect(&1, &2, nil))
    state = state |> settle() |> publish_fast() |> Mirror.flush() |> Load.finish()
    {:noreply, Carry.hold(state)}
  end

  @impl true
  def terminate(_reason, state), do: Mirror.flush(Map.merge(%__MODULE__{}, state))

  @impl true
  def code_change(_old, state, _extra) do
    state = Map.merge(%__MODULE__{}, state)
    {:ok, %{state | app: state.app && Upgrade.app(state.app)}}
  end

  @impl true
  def handle_call({:event, ev, size}, {origin, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, state |> handle_event(ev, size, origin) |> Mirror.dirty()}
  end

  def handle_call({:request, mfa}, {origin, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    before = state.app
    state = state |> handle_event({:run, mfa}, nil, origin) |> Mirror.dirty()
    {:reply, {:ok, before, state.app}, state}
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

  def handle_call({:unsubscribe, pid}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {ref, subs} = Map.pop(state.subs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subs: subs}}
  end

  def handle_call(:flush_hold, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, if(state.hold_timer, do: Carry.hold_now(state), else: state)}
  end

  def handle_call(:reset, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    Restore.close_all()
    :persistent_term.erase(Protocol.fast_path_key())
    for k <- [:session, :focus, :ui], do: HerdrServer.Mirror.delete({:app, k})
    {:reply, :ok, %__MODULE__{subs: state.subs, flush: state.flush}}
  end

  @impl true
  def handle_cast({:event, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state |> handle_event(ev, nil, nil) |> Mirror.dirty()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, handoff(%{state | subs: Map.delete(state.subs, pid)}, pid) |> Mirror.dirty()}
  end

  def handle_info(:flush, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Mirror.flush(%{state | flush: nil})}
  end

  def handle_info(:hold, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, Carry.hold_now(state)}
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

    if state.app != old do
      Enum.each(Map.keys(state.subs), &send(&1, {:app_changed, state.app}))
      Carry.hold(state)
    else
      state
    end
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
      # the batch is discarded; a driver resize already applied to the restored area
      {:restored, new} -> new
      :failed -> state
    end
  end

  defp step(state, step, origin) do
    opts = [server: reload_server()]

    result =
      case step do
        {:init, size} -> Guard.run_twice_attributed(Actions, :init, [size], opts)
        {:run, mfa} -> Guard.run_twice_attributed(Actions, :run, [state.app, mfa], opts)
        ev -> Guard.run_twice_attributed(Actions, :apply, [state.app, ev], opts)
      end

    case result do
      {:ok, {app, effects}} ->
        {:cont, {:ok, Enum.reduce(effects, %{state | app: app}, &effect(&2, &1, origin))}}

      {:failed, reason, batch} ->
        case restore(state, batch) do
          {:ok, state} ->
            restored_origin(state, origin, reason)
            {:halt, {:restored, state}}

          :none ->
            notice(origin, %{level: :error, text: "action failed: #{Guard.message(reason)}"})
            {:halt, :failed}
        end
    end
  end

  # subscribers got the restore warning; an origin that is not one (an API request)
  # learns that its action failed
  defp restored_origin(state, origin, reason) do
    if is_pid(origin) and not is_map_key(state.subs, origin),
      do: notice(origin, %{level: :error, text: "action failed: #{Guard.message(reason)}"})
  end

  @doc false
  # the reload server every herdr_server Guard call attributes to
  @spec reload_server() :: GenServer.server()
  def reload_server, do: Application.get_env(:herdr_server, :reload_server, HerdrReload.Server)

  # Batch `k`'s new code corrupted state the old code then failed on: go back to a state
  # from before `k` was loaded, reconciled with the keeper.
  defp restore(state, k) do
    with {:ok, id, at_load} <- Mirror.rollback_target(state, k),
         {:ok, restored} <- reconcile(state, at_load) do
      restored = %{restored | app: Mirror.keep_monotonic(restored.app, state.app)}
      n = %{level: :warning, text: "state restored to batch #{id}; actions since were lost"}

      if restored.subs == %{},
        do: notice(nil, n),
        else: Enum.each(Map.keys(restored.subs), &notice(&1, n))

      {:ok, restored}
    else
      _ -> :none
    end
  end

  defp adopt_carried(blob) do
    case Carry.adopt_carried(blob) do
      {:ok, app, sizes} ->
        Mirror.flush(publish_fast(%__MODULE__{app: app, sizes: sizes}))

      :failed ->
        # the keeper's adopted panes stay open but nothing maps them: an empty app
        lost(length(Kernel.keeper().ids()), :carry_unusable)
        %__MODULE__{}
    end
  end

  # live panes closed or orphaned in a running VM: a session loss for the exit criterion
  defp lost(0, _reason), do: :ok

  defp lost(n, reason),
    do: HerdrReload.Telemetry.event(:session_lost, proc: :store, reason: reason, panes: n)

  @doc false
  defdelegate adoption(blob), to: Carry

  defp effect(state, {:spawn, id, size}, origin),
    do: effect(state, {:spawn, id, size, %{cwd: nil, replay: nil}}, origin)

  # a restored pane (Persist.RestorePlan): its recorded cwd and saved scrollback
  defp effect(state, {:spawn, id, %{cols: c, rows: r}, opts}, origin) do
    # The kernel sets TERM=xterm-256color; Pane.Server subscribes when it starts. Children
    # inherit the OS environment of the VM, not `System.put_env/2` changes: extra
    # variables go in `config :herdr_server, :pane_env` (a list of {name, value}).
    spec = %{
      cmd: System.get_env("SHELL", "/bin/sh"),
      args: [],
      env: Application.get_env(:herdr_server, :pane_env, []) ++ [{"HERDR_PANE_ID", "p#{id}"}],
      cwd: opts.cwd || File.cwd!(),
      cols: c,
      rows: r,
      max_scrollback: @max_scrollback,
      replay: opts.replay,
      subscriber: nil
    }

    with {:ok, kid} <- open(spec, opts.cwd),
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

  # a reconciled pane already in the keeper and mapped; {0, 0} makes settle/1 size it
  defp effect(state, {:adopt, id}, _origin) do
    Restore.ensure_server(id)
    %{state | sizes: Map.put_new(state.sizes, id, {0, 0})}
  end

  defp effect(state, {:close, id}, _origin) do
    Restore.close(id)
    %{state | sizes: Map.delete(state.sizes, id), hidden: MapSet.delete(state.hidden, id)}
  end

  defp effect(state, other, origin) do
    io(other, origin)
    state
  end

  # a restored pane whose recorded cwd cannot be used gets one retry in the Store's cwd
  defp open(spec, nil), do: Kernel.keeper().open(spec)

  defp open(spec, _cwd) do
    with {:error, _} <- Kernel.keeper().open(spec),
         do: Kernel.keeper().open(%{spec | cwd: File.cwd!()})
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

  defp notice(origin, n) when is_pid(origin), do: send(origin, {:notice, n})
  defp notice(_origin, n), do: Logger.info("notice: #{inspect(n)}")

  # --- handoff ---
  # --- after every event ---

  defp settle(%{app: nil} = state), do: state

  # a failing Layout keeps the previous pane sizes and visibility
  defp settle(%{app: %{session: s}} = state) do
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    g = [scan: false, server: reload_server()]

    with {:ok, panes} <- Guard.run_twice(Layout, :panes, [tab.layout, s.area], g),
         {:ok, rects} <- Guard.run_twice(Layout, :borders, [panes, s.area], g) do
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
    case Guard.run_twice(Keybinds, :intercept_set, [ui.keybinds], server: reload_server()) do
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
