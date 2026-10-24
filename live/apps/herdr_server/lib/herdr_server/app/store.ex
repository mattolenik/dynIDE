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
    * `app.session`, `app.focus`, `app.ui` and the bookkeeping below (`@book`) are
      mirrored to `HerdrServer.Mirror`, debounced (one 20 ms timer; only changed entries
      are written). `terminate/2` flushes, but it only runs when a callback raises: the
      Store does not trap exits, so a kill or a supervisor shutdown loses the window
      (Reconcile adopts its panes). A restarted Store reconciles the mirrored
      app with the keeper (`App.Reconcile`: panes whose kernel is gone are dropped, live
      mapped panes the mirror lost, e.g. spawned within the debounce window, are adopted
      into a "scratch" tab; missing `Pane.Server`s restarted), re-monitors the mirrored
      sessions and republishes the fast path; sessions re-subscribe and push full scenes.
      Only an empty mirror (or a failing reconcile) starts fresh, closing whatever the
      keeper still holds. Other app writes inside the window (focus, titles) are lost.
    * A repeat failure of `Actions.apply` (the guard rolled back batch K and the old code
      failed on the same event too) restores the `state_at_load` of the reload server's
      `last_rolled_back/1` batch when it is K or older, reconciled with the keeper as
      above (keeping the current pane area, `next_id` and each pane's `layout_gen` at
      least their current values, so no id or gen is seen twice), and warns every
      subscriber.
      Without such a state, or on an unattributed failure, the event is discarded with an
      error notice.
      The reload server is `config :herdr_server, :reload_server` (default
      `HerdrReload.Server`).
    * Handoff (M5): with a broker, the latest app and the pane/keeper id map are held
      under `"app/store"` (`Handoff.Link.hold/3`) at most once per 100 ms after events
      that changed the app; `flush_hold/0` (the Link's PREPARE) holds a pending one now.
      A new VM's `init/1` that finds that entry adopts it (before looking at the mirror,
      which is empty in a new VM): it maps the panes the Keeper adopted in
      `:herdr_pane_kernel`, starts their `Pane.Server`s, and leaves every other keeper
      pane alone (they belong to whoever opened them, e.g. ctl). A mapped pane the Keeper
      lost is closed as `{:pane_exited, id}`. The adopted app is mirrored at once, so a
      later Store restart in this VM restarts from the mirror as above. An unusable entry
      (its pure part runs through `HerdrReload.Guard`) is logged and unclaimed, and the
      Store starts with an empty app.
    * In a VM that adopted panes (`Link.adopt_reason/0` not nil) no restart or restore
      closes a keeper pane nothing maps (`App.Restore`): it may be an adopted child.
  """
  use GenServer

  require Logger

  alias HerdrReload.Guard
  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Keybinds, Reconcile, Restore}
  alias HerdrServer.Handoff.Link
  alias HerdrServer.{Kernel, Layout, Mirror}
  alias HerdrServer.Pane.{Input, Rows, Server}
  alias HerdrServer.Pane.Supervisor, as: Panes

  # bytes of scrollback per pane
  @max_scrollback 10_000_000
  @hold_key "app/store"
  @hold_ms 100

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

  # Store fields mirrored as {:store, key}; `hidden` is recomputed by settle/1
  @book [:driver, :driver_pid, :clients, :sizes]
  @flush_ms 20

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

  @spec event_async(tuple) :: :ok
  def event_async(event), do: GenServer.cast(__MODULE__, {:event, event})

  @spec snapshot() :: Actions.app() | nil
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec subscribe(pid) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

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
    case Link.take_adopted(@hold_key) do
      [{_key, blob, _fds}] ->
        :persistent_term.erase(Protocol.fast_path_key())
        {:ok, adopt_carried(blob)}

      [] ->
        init_local()
    end
  end

  defp init_local do
    case Mirror.app() do
      nil ->
        # a fresh start: close what a previous incarnation without a mirror left open
        Restore.close_all()
        :persistent_term.erase(Protocol.fast_path_key())
        {:ok, %__MODULE__{}}

      app ->
        {:ok, adopt(app)}
    end
  end

  defp adopt(app) do
    book = Map.new(@book, &{&1, Mirror.get({:store, &1})})
    state = struct(%__MODULE__{}, Enum.reject(book, &(elem(&1, 1) == nil)))
    subs = Map.new(state.clients, fn {pid, _} -> {pid, Process.monitor(pid)} end)
    fast = :persistent_term.get(Protocol.fast_path_key(), nil)
    state = %{state | subs: subs, fast: fast}

    case reconcile(state, app) do
      {:ok, state} ->
        ids = Map.keys(state.app.session.panes)
        Enum.each(ids, &Restore.ensure_server/1)
        # settle only acts where it disagrees: start from what the pane servers hold
        hidden =
          for id <- ids, match?(%{hidden: true}, Mirror.pane(id)), into: MapSet.new(), do: id

        dirty(%{state | hidden: hidden}) |> settle() |> publish_fast()

      :failed ->
        Restore.close_all()
        :persistent_term.erase(Protocol.fast_path_key())
        %__MODULE__{subs: subs}
    end
  end

  defp reconcile(state, app) do
    case Guard.run_twice(Reconcile, :run, [app, Restore.live()], server: reload_server()) do
      {:ok, {app, effects}} ->
        {:ok, Enum.reduce(effects, %{state | app: app}, &effect(&2, &1, nil))}

      {:failed, _} ->
        :failed
    end
  end

  @impl true
  def terminate(_reason, state), do: flush(Map.merge(%__MODULE__{}, state))

  @impl true
  def handle_call({:event, ev, size}, {origin, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, state |> handle_event(ev, size, origin) |> dirty()}
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

  def handle_call(:flush_hold, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, if(state.hold_timer, do: hold_now(state), else: state)}
  end

  def handle_call(:reset, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    Restore.close_all()
    :persistent_term.erase(Protocol.fast_path_key())
    for k <- [:session, :focus, :ui], do: Mirror.delete({:app, k})
    {:reply, :ok, %__MODULE__{subs: state.subs, flush: state.flush}}
  end

  @impl true
  def handle_cast({:event, ev}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state |> handle_event(ev, nil, nil) |> dirty()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, handoff(%{state | subs: Map.delete(state.subs, pid)}, pid) |> dirty()}
  end

  def handle_info(:flush, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, flush(%{state | flush: nil})}
  end

  def handle_info(:hold, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, hold_now(state)}
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
      hold(state)
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
        {:run, {m, f, a}} -> Guard.run_twice_attributed(m, f, [state.app | a], opts)
        ev -> Guard.run_twice_attributed(Actions, :apply, [state.app, ev], opts)
      end

    case result do
      {:ok, {app, effects}} ->
        {:cont, {:ok, Enum.reduce(effects, %{state | app: app}, &effect(&2, &1, origin))}}

      {:failed, reason, batch} ->
        case restore(state, batch) do
          {:ok, state} ->
            {:halt, {:restored, state}}

          :none ->
            notice(origin, %{level: :error, text: "action failed: #{Guard.message(reason)}"})
            {:halt, :failed}
        end
    end
  end

  @doc false
  # the reload server every herdr_server Guard call attributes to
  @spec reload_server() :: GenServer.server()
  def reload_server, do: Application.get_env(:herdr_server, :reload_server, HerdrReload.Server)

  # Batch `k`'s new code corrupted state the old code then failed on: go back to a state
  # from before `k` was loaded (`k`'s own; the Guard's re-run never rolls back an older
  # batch), reconciled with the keeper.
  defp restore(%{app: app} = state, k) when is_integer(k) and app != nil do
    with {:ok, id, at_load} when id <= k and at_load != nil <- last_rolled_back(),
         at_load = put_in(at_load.session.area, app.session.area),
         {:ok, state} <- reconcile(state, at_load) do
      state = %{state | app: keep_monotonic(state.app, app)}
      n = %{level: :warning, text: "state restored to batch #{id}; actions since were lost"}

      if state.subs == %{},
        do: notice(nil, n),
        else: Enum.each(Map.keys(state.subs), &notice(&1, n))

      {:ok, state}
    else
      _ -> :none
    end
  end

  defp restore(_state, _k), do: :none

  # A ref client re-fetches a pane only when its layout_gen changes: a restored older gen
  # (or an adopted pane's 0) would repeat one it has seen, with another size. Pane ids
  # spawned (and maybe closed) since the load must not be handed out again either.
  defp keep_monotonic(restored, app) do
    gens = for {id, %{layout_gen: g}} <- app.session.panes, into: %{}, do: {id, g}
    restored = update_in(restored.session.next_id, &max(&1, app.session.next_id))

    update_in(restored.session.panes, fn panes ->
      Map.new(panes, fn {id, m} -> {id, %{m | layout_gen: max(m.layout_gen, gens[id] || 0)}} end)
    end)
  end

  # ponytail: a reload server dying between whereis and the call crashes the Store,
  # which then restarts from the mirror
  defp last_rolled_back do
    server = reload_server()
    if GenServer.whereis(server), do: HerdrReload.Server.last_rolled_back(server), else: :none
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

  # coalesced: one HOLD of the latest app per @hold_ms (the app can change per event)
  defp hold(%{hold_timer: nil} = state) do
    if Link.enabled?(),
      do: %{state | hold_timer: Process.send_after(self(), :hold, @hold_ms)},
      else: state
  end

  defp hold(state), do: state

  defp hold_now(state) do
    if state.hold_timer, do: Process.cancel_timer(state.hold_timer)

    if state.app != nil do
      blob = :erlang.term_to_binary(%{v: 1, app: state.app, kernel_ids: Rows.kernel_ids()})
      Link.hold(@hold_key, blob, [])
    end

    %{state | hold_timer: nil}
  end

  defp adopt_carried(blob) do
    case Guard.run_twice(__MODULE__, :adoption, [blob], server: reload_server()) do
      {:ok, {app, pairs}} ->
        adopt_carried(app, pairs)

      # the keeper's panes are left alone, as unmapped ones are below
      {:failed, reason} ->
        Logger.error("handoff: unusable app/store entry: #{inspect(reason, limit: 5)}")
        Link.unclaim(@hold_key)
        %__MODULE__{}
    end
  end

  @doc false
  # The pure part of an adoption: the carried app and `[{pane_id, kernel_id | nil}]` for
  # its panes. Raises on an entry of the wrong shape.
  @spec adoption(binary) :: {Actions.app(), [{pos_integer, pos_integer | nil}]}
  def adoption(blob) do
    %{v: 1, app: %{session: %{panes: %{} = panes}} = app, kernel_ids: kids} =
      :erlang.binary_to_term(blob, [:safe])

    kids = Map.new(kids)
    {app, Enum.map(Map.keys(panes), &{&1, Map.get(kids, &1)})}
  end

  defp adopt_carried(app, pairs) do
    keeper = Kernel.keeper()
    live = Enum.filter(pairs, fn {id, kid} -> start_adopted(id, kid, keeper) end)
    # after init: drops the pane from the layout and closes whatever is left of it
    Enum.each(pairs -- live, fn {id, _} -> event_async({:pane_exited, id}) end)
    unmapped = keeper.ids() -- Enum.map(live, &elem(&1, 1))
    if unmapped != [], do: Logger.info("handoff: keeper panes left alone: #{inspect(unmapped)}")
    Logger.info("handoff: adopted app with panes #{inspect(Enum.map(live, &elem(&1, 0)))}")
    # sizes are unknown here: {0, 0} makes the next settle resize each visible pane to
    # its rect (the same size it has, so no SIGWINCH)
    sizes = Map.new(live, fn {id, _} -> {id, {0, 0}} end)
    # mirrored now: a Store restart in this VM must find the carried app, not close it
    flush(publish_fast(%__MODULE__{app: app, sizes: sizes}))
  end

  defp start_adopted(_id, nil, _keeper), do: false

  defp start_adopted(id, kid, keeper) do
    with {:ok, _} <- keeper.lookup(kid),
         :ok <- Rows.put_kernel_id(id, kid),
         {:ok, pid} when is_pid(pid) <- Panes.start_pane(id) do
      true
    else
      _ -> false
    end
  end

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

  # --- mirror ---

  defp dirty(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @flush_ms)}

  defp dirty(state), do: state

  defp flush(%{app: nil} = state), do: state

  defp flush(%{app: app} = state) do
    entries =
      Map.new(@book, &{{:store, &1}, Map.fetch!(state, &1)})
      |> Map.merge(Map.new([:session, :focus, :ui], &{{:app, &1}, Map.fetch!(app, &1)}))

    %{state | mirrored: Mirror.put_changed(entries, state.mirrored)}
  end
end
