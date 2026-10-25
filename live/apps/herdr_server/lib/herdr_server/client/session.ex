defmodule HerdrServer.Client.Session do
  @moduledoc """
  One per attached client (`restart: :temporary`; a crash is a detach from the client's
  point of view). Owns the client's `Client.State`, computes its scene with `View.compute/2`
  (through `HerdrReload.Guard`) and pushes `{:scene, scene}` only when it differs from the last one.

  Ref transport: scenes carry `{:ref, id, layout_gen}` and no cursors; pane damage is
  forwarded as `{:damage, id, gen}` and the client reads rows and cursor from
  `Pane.Rows`. Inline transport: every pushed scene carries each pane's full rows and
  cursors plus the host `scene.cursor`; damage is forwarded as `{:rows, id, gen, rows}`
  (full rows), and damage that moves the focused pane's cursor re-pushes the scene.
  Damage for a pane not in the last scene is dropped: it belongs to a scene still on
  its way (the Store notifies after the event that spawned the pane), and that scene
  brings the pane's rows (inline: filled here; ref: fetched by the client for new refs).

  Client input is validated (server-internal events are refused with a warning notice)
  and always acked. Keys are resolved per client by `Client.Keys` (this client's mode and
  consumed-press set, so one client's prefix never captures another's keys): a forwarded
  press takes the fast path when the published record allows it, other forwarded keys
  go to `App.Store.event/2`, bindings to `App.Store.run/2`. When the client's mode
  changes, the session sends `{:input_mode, mode}` to the input's `from` pid before its
  `{:ack, seq}`, and re-pushes the scene (the status shows the mode). While the app's
  top modal captures keys (`App.Modal.capturing?/1`, cached in `state.capture` from each
  pushed app) keys skip `Client.Keys` and go to `App.Store.event/2`. Non-key events go
  to `App.Store` with this client's size. The session monitors the Store; when it dies
  the session waits for the restarted one (polling every 10 ms, up to 1 s, else it
  stops), re-subscribes and pushes a full scene of the adopted app.

  The presentation fields (`@presentation`) are mirrored per client pid
  (`HerdrServer.Mirror.client/1`) when an input changes them; `info.mirrored` (from
  `Client.Endpoint`) seeds them on a re-attach. The entry goes when the session stops
  normally (client gone, detach, Store gone); a crash keeps it for the re-attach.
  If the restarted Store dies while the session re-subscribes, the client gets
  `{:detached, :store_restart}`.

  Runtime status: `{:runtime_status, st}` from `ReloadNotices` (seeded in init from
  `Mirror.get(:runtime_status)`) is kept in `state.runtime` for View's status line; a
  changed status repaints (the scene is pushed only if it differs).

  Window title: `{:window_title, title | nil}` (API `client.window_title.set|clear`) sets the
  client's override; `hostname` is read once in init.

  Alerts (M13): `{:alert, a}` from the Store goes through `Client.Toasts` with the app and
  this client's last `{:focus, bool}`: forwarded to the client (or not) and queued as a
  toast that expires after 8 s (attention) or 5 s (`config :herdr_server, :toast_ms`);
  a click on `[{:toast, id}]` dismisses it and focuses its pane.

  Handoff (M5): every `Handoff.Notice` event is forwarded verbatim (`{:handoff, map}`).
  From `:begin` input is held: it gets no ack (one warning notice per handoff), so the
  client keeps it unacked (at-least-once: resent first to its next session, in the new
  VM). `:aborted` runs the held input in order, acking each. Holding starts as soon as
  the Link publishes `:begin` (before the notice reaches this mailbox), and an input
  whose fast-path write finds its pane frozen (`:closed` while the published phase is
  `:begin`) is held instead of acked; `:closed` otherwise (an exited pane) is dropped and acked.
  ponytail: a slow-path write (through `App.Store`) racing the freeze is still acked
  and lost; route Store writes' results back if that window matters. The in-VM local client stops
  on `:begin`: keystrokes it already read between `:begin` and its stop are dropped (a
  small window); unread ones stay in the host tty's input queue for the next client.

  Pointer (M9): mouse input goes through `Client.Pointer` (pure, guarded) with a
  context from `Client.PointerIo`, which then executes the actions; a failure forwards
  the event to the Store as before. Selection and hover live in `state.pointer` (per
  client); a change repaints. Autoscroll ticks every 30 ms; a kept word highlight
  expires after 500 ms. Each push prunes pointer state of panes that left or resized,
  before the scene is computed. This session becomes the foreground client
  (`Client.Foreground`) on attach and on each slow-path input; pane bells and child clipboard writes sent to it
  go to the client as `{:bell, id}` and `{:clipboard, %{source: :pane}}`, and
  `{:pane_facts, id}` repaints when the pane is in the last scene (at once, then at most
  once per 16 ms, `HerdrServer.Throttle`, the last one trailing). `{:caps, map}` merges
  into `state.caps`; the foreground session's also go to `Pane.Colors.apply_all/1`, and
  a session that becomes the foreground client re-applies its stored colours.

  Copy mode (M9): entering mode `:copy` starts a `Client.CopyMode` (`state.copy`) on the
  focused pane and clears the pointer selection; in that mode `Client.Keys` consumes
  every key and the session hands presses to `CopyMode.key/3` (guarded, context from
  `PointerIo.copy_context/2`), executing its actions with `PointerIo.run/3`. Its exit,
  a failure, or the copy pane losing the app focus sets the mode back to `:terminal`.
  """
  use GenServer, restart: :temporary

  alias HerdrReload.Guard
  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Keybinds, Modal, Store}
  alias HerdrServer.Client.{CopyMode, Foreground, Keys, Pointer, PointerIo, State, Toasts}
  alias HerdrServer.Handoff.Notice
  alias HerdrServer.Layout
  alias HerdrServer.Mirror
  alias HerdrServer.Pane.{Colors, Facts, Rows}
  alias HerdrServer.Throttle
  alias HerdrServer.View

  @presentation [:viewports, :hover, :mode, :swallow]
  @store_wait_ms 10
  @store_tries 100

  def start_link(info), do: GenServer.start_link(__MODULE__, info)

  @doc "The mirrored subset of a `Client.State`."
  @spec presentation(State.t()) :: map
  def presentation(state), do: Map.take(state, @presentation)

  @impl true
  def init(info) do
    {:ok, _} = Registry.register(HerdrServer.Client.Registry, :clients, nil)
    :ok = Store.subscribe(self())
    :ok = Notice.subscribe()

    state = %State{
      kind: info.kind,
      transport: info.transport,
      size: Map.take(info.size, [:cols, :rows]),
      cell_px: info.cell_px,
      caps: info.caps,
      client: info.client,
      monitor: Process.monitor(info.client),
      store_monitor: Process.monitor(Store),
      runtime: Mirror.get(:runtime_status),
      hostname: hostname()
    }

    state = struct(state, Map.take(info[:mirrored] || %{}, @presentation))
    # copy mode's state is not mirrored: a re-attach starts outside it
    state = if state.mode == :copy, do: %{state | mode: :terminal}, else: state

    {:ok, state, {:continue, :attach}}
  end

  @impl true
  def handle_continue(:attach, state) do
    state = Map.merge(%State{}, state)
    # a mirrored mode: the client reset its own to :terminal for this new session
    if state.mode != :terminal, do: send(state.client, {:input_mode, state.mode})
    become_foreground(state)
    {:noreply, resized(state)}
  end

  @impl true
  def handle_info({:app_changed, app}, state) do
    state = Map.merge(%State{}, state)
    {:noreply, push(state, app)}
  end

  def handle_info({:pane_damage, id, gen}, state) do
    state = Map.merge(%State{}, state)
    gen = latest(id, gen)

    # a selection's pane may have switched screens (one ETS read, only with a selection)
    state =
      case state.pointer.alt do
        {^id, _} -> pointer_facts(state, id, false, &repaint/1)
        _ -> state
      end

    scene = state.last_scene

    if scene != nil and Enum.any?(scene.panes, &(&1.id == id)),
      do: {:noreply, damaged(state, scene, id, gen)},
      else: {:noreply, state}
  end

  def handle_info({:input, _, _, _} = msg, %{held: held} = state) when is_list(held) do
    state = Map.merge(%State{}, state)

    if held == [],
      do: send(state.client, {:notice, %{level: :warning, text: "input held during handoff"}})

    {:noreply, %{state | held: [msg | held]}}
  end

  def handle_info({:input, _, _, _} = msg, state) do
    state = Map.merge(%State{}, state)

    if :persistent_term.get(Protocol.handoff_key(), nil) == :begin do
      # the panes may be freezing already: hold, as after the :begin notice
      handle_info(msg, %{state | held: []})
    else
      unheld(msg, state)
    end
  end

  def handle_info({:handoff, %{phase: phase}} = event, state) do
    state = Map.merge(%State{}, state)
    send(state.client, event)

    case phase do
      :begin ->
        {:noreply, %{state | held: state.held || []}}

      :aborted ->
        held = Enum.reverse(state.held || [])

        {:noreply, Enum.reduce(held, %{state | held: nil}, &elem(handle_info(&1, &2), 1))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:notice, n}, state) do
    state = Map.merge(%State{}, state)
    {:noreply, notice(state, n)}
  end

  # the runtime status line (`ReloadNotices`): repaint only when it changed
  def handle_info({:runtime_status, st}, state) do
    state = Map.merge(%State{}, state)

    if st == state.runtime,
      do: {:noreply, state},
      else: {:noreply, repaint(%{state | runtime: st})}
  end

  # `title set|clear` (API `client.window_title.*`): this client's override, nil clears
  def handle_info({:window_title, title}, state) do
    state = Map.merge(%State{}, state)
    {:noreply, repaint(%{state | window_title: title})}
  end

  def handle_info({:notice_expired, ref}, %{notice: %{ref: ref}} = state) do
    state = Map.merge(%State{}, state)
    {:noreply, repaint(%{state | notice: nil})}
  end

  # an agent alert (`App.Alerts`, broadcast by the Store): `Client.Toasts` decides
  def handle_info({:alert, a}, state) do
    state = Map.merge(%State{}, state)
    {:noreply, alerted(state, a)}
  end

  def handle_info({:toast_expired, id}, state) do
    state = Map.merge(%State{}, state)
    {_, toasts} = Toasts.drop(state.toasts, id)
    {:noreply, if(toasts == state.toasts, do: state, else: repaint(%{state | toasts: toasts}))}
  end

  # the protocol's client -> server detach message, or the Store's {:detach} effect for an
  # event from this session
  def handle_info({:detach}, state) do
    state = Map.merge(%State{}, state)
    Mirror.delete({:client, state.client})
    send(state.client, {:detached, :requested})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    state = Map.merge(%State{}, state)
    Mirror.delete({:client, state.client})
    {:stop, :normal, state}
  end

  # the Store restarted from the mirror: follow it and repaint in full
  def handle_info({:DOWN, ref, :process, _, _}, %{store_monitor: ref} = state) do
    state = Map.merge(%State{}, state)

    case await_store(@store_tries) do
      nil ->
        Mirror.delete({:client, state.client})
        {:stop, :normal, state}

      pid ->
        state = %{state | store_monitor: Process.monitor(pid), last_scene: nil}

        case follow() do
          {:ok, app} ->
            {:noreply, push(state, app)}

          :error ->
            Mirror.delete({:client, state.client})
            send(state.client, {:detached, :store_restart})
            {:stop, :normal, state}
        end
    end
  end

  def handle_info({:pane_bell, id}, state) do
    state = Map.merge(%State{}, state)
    send(state.client, {:bell, id})
    {:noreply, state}
  end

  def handle_info({:pane_clipboard, _id, text}, state) do
    state = Map.merge(%State{}, state)
    send(state.client, {:clipboard, %{text: text, source: :pane}})
    {:noreply, state}
  end

  # host colours and scheme (protocol `{:caps, map}`); the foreground client's set every pane
  def handle_info({:caps, caps}, state) when is_map(caps) do
    state = Map.merge(%State{}, state)
    if Foreground.current() == self(), do: Guard.run_twice(Colors, :apply_all, [caps], guard())
    {:noreply, %{state | caps: Map.merge(state.caps || %{}, caps)}}
  end

  def handle_info({:pane_facts, id}, state) do
    state = Map.merge(%State{}, state)
    p = state.pointer

    state =
      if match?({^id, _}, p.alt) or match?(%{pane: ^id}, p.hover),
        do: pointer_facts(state, id, true, & &1),
        else: state

    if state.last_scene != nil and Enum.any?(state.last_scene.panes, &(&1.id == id)),
      do: {:noreply, facts_repaint(state, &Throttle.hit/1)},
      else: {:noreply, state}
  end

  def handle_info(:facts_tick, state) do
    state = Map.merge(%State{}, state)
    {:noreply, facts_repaint(state, &Throttle.tick/1)}
  end

  def handle_info({:autoscroll, ref}, %{pointer_refs: %{autoscroll: ref}} = state) do
    state = Map.merge(%State{}, state)
    state = %{state | pointer_refs: Map.delete(state.pointer_refs, :autoscroll)}
    ctx = Guard.run_twice(PointerIo, :context, [state.pointer, nil, state.last_scene], guard())

    with {:ok, ctx} <- ctx,
         %State{} = new <- pointer_run(state, Pointer, :tick, [state.pointer, ctx]) do
      # keep ticking while the pointer holds an edge
      if new.pointer.autoscroll != nil and not is_map_key(new.pointer_refs, :autoscroll),
        do: {:noreply, arm(new, :autoscroll, 30, &{:autoscroll, &1}, & &1)},
        else: {:noreply, new}
    else
      # a later edge drag re-arms
      _failed -> {:noreply, %{state | pointer: %{state.pointer | autoscroll: nil}}}
    end
  end

  def handle_info({:selection_expired, ref}, %{pointer_refs: %{expire: {ref, sel}}} = state) do
    state = Map.merge(%State{}, state)
    state = %{state | pointer_refs: Map.delete(state.pointer_refs, :expire)}
    p = state.pointer

    if p.selection == sel and p.press == nil,
      do: {:noreply, repaint(%{state | pointer: %{p | selection: nil}})},
      else: {:noreply, state}
  end

  # stale damage for closed panes, unknown messages: ignore
  def handle_info(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%State{}, state)}

  defp hostname do
    {:ok, h} = :inet.gethostname()
    List.to_string(h)
  end

  # the new Store may die too while we call it
  defp follow do
    :ok = Store.subscribe(self())
    {:ok, Store.snapshot()}
  catch
    :exit, _ -> :error
  end

  defp await_store(0), do: nil

  defp await_store(n) do
    with nil <- Process.whereis(Store) do
      Process.sleep(@store_wait_ms)
      await_store(n - 1)
    end
  end

  # --- notices ---

  # Forwarded to the client and shown in the status line until it expires (info 3 s,
  # warning 8 s, `config :herdr_server, :notice_ms`) or a newer notice replaces it. A
  # reload error stays until then (the next reload's notice replaces it).
  # The same level and text again only re-arms the timer (no repaint).
  defp notice(state, %{level: level, text: text} = n) do
    send(state.client, {:notice, n})
    ref = make_ref()
    ms = Application.get_env(:herdr_server, :notice_ms, info: 3000, warning: 8000)

    if level != :error or n[:source] != :reload do
      t = if level == :info, do: ms[:info], else: ms[:warning]
      Process.send_after(self(), {:notice_expired, ref}, t)
    end

    new = %{level: level, text: text, ref: ref}

    case state.notice do
      %{level: ^level, text: ^text} -> %{state | notice: new}
      _ -> repaint(%{state | notice: new})
    end
  end

  # facts repaints: at once, then at most one per 16 ms window (the last one trailing)
  defp facts_repaint(state, step) do
    case step.(state.facts_tick) do
      {:fire, tick} ->
        Process.send_after(self(), :facts_tick, 16)
        repaint(%{state | facts_tick: tick})

      {:skip, tick} ->
        %{state | facts_tick: tick}
    end
  end

  # the Store may be restarting: the session follows it and repaints then
  defp repaint(state) do
    push(state, Store.snapshot())
  catch
    :exit, _ -> state
  end

  defp unheld({:input, from, seq, ev} = msg, state) do
    state =
      case Protocol.validate_client_msg(msg) do
        :ok ->
          input(state, ev, from)

        {:error, why} ->
          notice(state, %{level: :warning, text: "input rejected: " <> why})
      end

    case state.held do
      # the write found the pane frozen: the handoff has begun, keep the input
      [] ->
        send(state.client, {:notice, %{level: :warning, text: "input held during handoff"}})
        {:noreply, %{state | held: [msg]}}

      _ ->
        if is_pid(from), do: send(from, {:ack, seq})
        {:noreply, state}
    end
  end

  # --- input ---

  # presentation fields can only change on input: mirror them then
  defp input(state, ev, from) do
    new = apply_input(state, ev, from)
    p = presentation(new)
    if p != presentation(state), do: Mirror.put({:client, new.client}, p)
    new
  end

  defp apply_input(state, {:resize, %{cols: c, rows: r} = m}, _from) do
    resized(%{state | size: %{cols: c, rows: r}, cell_px: m.cell_px})
  end

  # a capturing modal (keybind capture) takes every key, the prefix too: no Client.Keys
  defp apply_input(%{capture: true} = state, {:key, _} = ev, _from) do
    become_foreground(state)
    Store.event(ev, driving_size(state))
    state
  end

  defp apply_input(%{keybinds: %{}} = state, {:key, _} = ev, from) do
    case Guard.run_twice(Keys, :resolve, [Map.take(state, [:mode, :swallow]), state.keybinds, ev],
           server: Store.reload_server()
         ) do
      {:ok, {%{mode: mode, swallow: swallow}, result}} ->
        new = copy_mode(%{state | mode: mode, swallow: swallow}, state.mode, ev)
        new = keyed(new, state.mode, result, from)
        if new.mode == state.mode and new.copy != state.copy, do: repaint(new), else: new

      # a broken resolver (failure or bad shape) still lets the client type
      other ->
        become_foreground(state)
        Store.event(ev, driving_size(state))
        notice(state, %{level: :error, text: "keys failed: #{inspect(other)}"})
    end
  end

  defp apply_input(state, {:focus, f} = ev, _from) do
    become_foreground(state)
    Store.event(ev, driving_size(state))
    %{state | focused: f}
  end

  # a toast is this client's: a click dismisses it and focuses its pane
  defp apply_input(state, {:chrome, [{:toast, id} | _], {kind, _}}, _from) do
    become_foreground(state)

    case Toasts.drop(state.toasts, id) do
      {%{pane: pane}, rest} when kind == :click ->
        if pane, do: Store.run({Actions, :focus_pane, [pane]}, driving_size(state))
        repaint(%{state | toasts: rest})

      _ ->
        state
    end
  end

  defp apply_input(state, {:mouse, _} = ev, _from) do
    become_foreground(state)
    ctx = Guard.run_twice(PointerIo, :context, [state.pointer, ev, state.last_scene], guard())

    with {:ok, ctx} <- ctx,
         %State{} = new <- pointer_run(state, Pointer, :resolve, [state.pointer, ev, ctx]) do
      new
    else
      # a broken pointer still lets the mouse through, as before M9
      _ ->
        Store.event(ev, driving_size(state))
        state
    end
  end

  defp apply_input(state, ev, _from) do
    become_foreground(state)
    Store.event(ev, driving_size(state))
    state
  end

  defp alerted(state, a) do
    app = Store.snapshot()
    id = System.unique_integer([:positive])
    args = [state.toasts, a, app, state.focused, id]

    # a failing policy still lets the client hear the alert
    {fwd, toasts} =
      case Guard.run_twice(Toasts, :alert, args, scan: false, server: Store.reload_server()) do
        {:ok, {_, _} = r} -> r
        _ -> {a, state.toasts}
      end

    if fwd, do: send(state.client, {:alert, fwd})
    ms = Toasts.ttl(a.level, Application.get_env(:herdr_server, :toast_ms, []))
    if toasts != state.toasts, do: Process.send_after(self(), {:toast_expired, id}, ms)

    push(%{state | toasts: toasts}, app)
  catch
    # the Store is restarting: the session follows it and repaints then
    :exit, _ -> state
  end

  defp keyed(state, old_mode, result, from) do
    state =
      case result do
        {:forward, ev} ->
          case fast_path(ev) do
            true ->
              state

            false ->
              become_foreground(state)
              Store.event(ev, driving_size(state))
              state

            :closed ->
              %{state | held: []}
          end

        {:run, mfa} ->
          become_foreground(state)
          Store.run(mfa, driving_size(state))
          state

        _consumed ->
          state
      end

    if state.mode == old_mode do
      state
    else
      if is_pid(from), do: send(from, {:input_mode, state.mode})
      push(state, Store.snapshot())
    end
  end

  defp driving_size(state), do: Map.put(state.size, :cell_px, state.cell_px)

  # --- copy mode ---

  # entering: start on the focused pane, or stay out of copy mode
  defp copy_mode(%{mode: :copy, copy: nil} = state, _old, _ev) do
    with %{focus: %{pane: id}} = scene when id != nil <- state.last_scene,
         {:ok, %{} = ctx} <- Guard.run_twice(PointerIo, :copy_context, [id, scene], guard()),
         {:ok, %CopyMode{} = copy} <- Guard.run_twice(CopyMode, :enter, [id, ctx], guard()) do
      %{state | copy: copy, pointer: %{state.pointer | selection: nil}}
    else
      _ -> %{state | mode: :terminal}
    end
  end

  defp copy_mode(%{mode: :copy, copy: copy} = state, :copy, {:key, %{event: e}} = ev)
       when e != :release do
    ctx = Guard.run_twice(PointerIo, :copy_context, [copy.pane, state.last_scene], guard())

    with {:ok, %{} = ctx} <- ctx,
         {:ok, result} <- Guard.run_twice(CopyMode, :key, [copy, ev, ctx], guard()) do
      case result do
        {%CopyMode{} = copy, actions} when is_list(actions) ->
          copy_run(%{state | copy: copy}, actions)

        {:exit, actions} when is_list(actions) ->
          copy_left(state, actions)

        bad ->
          copy_failed(state, copy, {:bad_result, bad})
      end
    else
      # the pane is gone (copy_follow usually saw it first)
      {:ok, nil} -> copy_left(state, copy_leave(copy))
      failed -> copy_failed(state, copy, failed)
    end
  end

  defp copy_mode(state, _old, _ev), do: state

  defp copy_failed(state, copy, why) do
    state = copy_left(state, copy_leave(copy))
    notice(state, %{level: :error, text: "copy mode failed: #{inspect(why)}"})
  end

  defp copy_leave(copy) do
    case Guard.run_twice(CopyMode, :leave, [copy], guard()) do
      {:ok, actions} when is_list(actions) -> actions
      _failed -> []
    end
  end

  defp copy_left(state, actions), do: copy_run(%{state | mode: :terminal, copy: nil}, actions)

  defp copy_run(state, []), do: state

  defp copy_run(state, actions) do
    io = %{client: state.client, size: driving_size(state)}

    # impure: never re-run
    case Guard.run(PointerIo, :run, [actions, state.pointer, io], guard()) do
      {:ok, {%Pointer{} = p, notices}} when is_list(notices) ->
        Enum.reduce(notices, %{state | pointer: p}, &notice(&2, &1))

      other ->
        notice(state, %{level: :error, text: "copy mode failed: #{inspect(other)}"})
    end
  end

  # the copy pane lost the app focus (focus moved, pane closed, tab switched): leave
  defp copy_follow(%{copy: %CopyMode{pane: id} = copy} = state, %{focus: %{pane: focus}})
       when focus != id do
    send(state.client, {:input_mode, :terminal})
    state = copy_left(state, copy_leave(copy))
    Mirror.put({:client, state.client}, presentation(state))
    state
  end

  defp copy_follow(state, _app), do: state

  defp guard, do: [server: Store.reload_server()]

  # Marks this session the foreground client; on a change, its own host colours (if
  # it sent any) go to every pane.
  defp become_foreground(state) do
    was = Foreground.current()
    :ok = Foreground.mark(self())

    if was != self() and is_map_key(state.caps || %{}, :colors),
      do: Guard.run_twice(Colors, :apply_all, [Map.take(state.caps, [:colors, :scheme])], guard())

    :ok
  end

  # --- pointer ---

  # Runs a guarded `Pointer` step, executes its actions; :error when the step failed
  defp pointer_run(state, mod, fun, args) do
    case Guard.run_twice(mod, fun, args, guard()) do
      {:ok, {%Pointer{} = p, actions}} when is_list(actions) -> pointed(state, p, actions)
      _failed -> :error
    end
  end

  defp pointed(state, p, actions) do
    io = %{client: state.client, size: driving_size(state)}

    # impure: never re-run (a re-run would repeat its side effects)
    {p, notices} =
      case Guard.run(PointerIo, :run, [actions, p, io], guard()) do
        {:ok, {%Pointer{} = p, notices}} when is_list(notices) -> {p, notices}
        other -> {p, [%{level: :error, text: "pointer failed: #{inspect(other)}"}]}
      end

    old = state.pointer
    state = pointer_timers(%{state | pointer: p}, actions)
    state = Enum.reduce(notices, state, &notice(&2, &1))

    if :repaint in actions or {old.selection, old.hover} != {p.selection, p.hover},
      do: repaint(state),
      else: state
  end

  defp pointer_timers(state, actions) do
    Enum.reduce(actions, state, fn
      {:autoscroll, _, _}, %{pointer_refs: %{autoscroll: _}} = s ->
        s

      {:autoscroll, _, _}, s ->
        arm(s, :autoscroll, 30, &{:autoscroll, &1}, & &1)

      :autoscroll_stop, s ->
        %{s | pointer_refs: Map.delete(s.pointer_refs, :autoscroll)}

      {:expire_selection, ms}, s ->
        arm(s, :expire, ms, &{:selection_expired, &1}, &{&1, s.pointer.selection})

      _, s ->
        s
    end)
  end

  defp arm(state, key, ms, msg, value) do
    ref = make_ref()
    Process.send_after(self(), msg.(ref), ms)
    %{state | pointer_refs: Map.put(state.pointer_refs, key, value.(ref))}
  end

  # `changed` (repaint or not) runs when the facts cleared pointer state
  defp pointer_facts(state, id, offset?, changed) do
    with {:ok, %{} = facts} <- Guard.run_twice(PointerIo, :facts, [id, offset?], guard()),
         {:ok, %Pointer{} = p} when p != state.pointer <-
           Guard.run_twice(Pointer, :facts, [state.pointer, id, facts], guard()) do
      changed.(%{state | pointer: p})
    else
      _ -> state
    end
  end

  defp focus_moved(state, %{focus: %{pane: new}}) do
    old = state.last_scene && state.last_scene.focus.pane

    case Guard.run_twice(Pointer, :focus_moved, [state.pointer, old, new], guard()) do
      {:ok, %Pointer{} = p} -> %{state | pointer: p}
      _failed -> state
    end
  end

  defp focus_moved(state, _app), do: state

  # Same check as an in-VM client (contract decision 6), for remote/GUI clients, after
  # `Client.Keys` forwarded the key (so this client's own mode allowed it). Releases go
  # through the Store.
  defp fast_path({:key, %{key: k, mods: m, event: e}} = ev) when e != :release do
    case :persistent_term.get(Protocol.fast_path_key(), nil) do
      %{passthrough: true, write: {mod, f, a}, intercept: i} ->
        # a failure in either call sends the event the slow path
        with {:ok, key} <-
               Guard.run_twice(Keybinds, :normalize, [k, m], server: Store.reload_server()),
             false <- MapSet.member?(i, key),
             # ponytail: a write that writes then raises is re-sent after a rollback
             do:
               fast_write(
                 Guard.run_twice(mod, f, [ev | a], scan: false, server: Store.reload_server())
               ),
             else: (_ -> false)

      _ ->
        false
    end
  end

  defp fast_path(_ev), do: false

  defp fast_write({:ok, :ok}), do: true

  # frozen for a handoff: the caller holds the input unacked. Outside a handoff `:closed`
  # is an exited pane: drop and ack like any write error, or the session would wedge.
  defp fast_write({:ok, {:error, :closed}}) do
    if :persistent_term.get(Protocol.handoff_key(), nil) == :begin, do: :closed, else: true
  end

  # another write error dropped the input already (as before)
  defp fast_write({:ok, {:error, _}}), do: true
  defp fast_write(_failed), do: false

  defp resized(state) do
    :ok = Store.event({:resize, driving_size(state)}, driving_size(state))
    push(state, Store.snapshot())
  end

  # --- output ---

  defp latest(id, gen) do
    receive do
      {:pane_damage, ^id, g} -> latest(id, g)
    after
      0 -> gen
    end
  end

  defp damaged(%{transport: :inline} = state, scene, id, gen) do
    case Rows.fetch(id) do
      {_gen, rows, cursor} ->
        moved? = Enum.any?(scene.panes, &(&1.id == id and &1.cursor != cursor))

        # ponytail: the focused cursor moving re-pushes every pane's full rows (the scene
        # carries them, so no {:rows} then); M16 sends cursor-only updates
        if moved? and scene.focus.pane == id do
          send_scene(state, fill(scene))
        else
          send(state.client, {:rows, id, gen, indexed(rows)})
          state
        end

      nil ->
        state
    end
  end

  defp damaged(state, _scene, id, gen) do
    send(state.client, {:damage, id, gen})
    state
  end

  defp push(state, nil), do: state

  defp push(state, app) do
    # every app the session sees, before View reads the pointer
    state = state |> focus_moved(app) |> copy_follow(app)

    # outside the guard: an app without keybinds (a broken Store) must not crash us
    state =
      case app do
        %{ui: %{keybinds: kb}} -> %{state | keybinds: kb, capture: capturing?(app)}
        _ -> state
      end

    case view(state, app) do
      {:ok, scene} ->
        # drop selection/hover of panes that left or resized BEFORE they reach a scene
        {state, scene} = pruned(state, app, scene)
        send_scene(state, if(state.transport == :inline, do: fill(scene), else: scene))

      {:failed, reason} ->
        send(
          state.client,
          {:notice, %{level: :error, text: "view failed: #{Guard.message(reason)}"}}
        )

        state
    end
  end

  # a failing check never captures: the client keeps its keys
  defp capturing?(%{focus: focus}) do
    case Guard.run_twice(Modal, :capturing?, [focus], scan: false, server: Store.reload_server()) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp capturing?(_app), do: false

  # the budget copies args into a worker: pass only what View reads, never last_scene
  defp view(state, app) do
    ids = active_ids(app)

    view_state = %State{
      size: state.size,
      transport: state.transport,
      mode: state.mode,
      notice: state.notice,
      runtime: state.runtime,
      toasts: state.toasts,
      pointer: state.pointer,
      copy: state.copy,
      facts: facts(state, ids),
      graphics: graphics(ids),
      window_title: state.window_title,
      hostname: state.hostname
    }

    Guard.run_twice(View, :compute, [app, view_state],
      budget_ms: 50,
      scan: false,
      server: Store.reload_server()
    )
  end

  defp active_ids(app) do
    with %{session: %{workspaces: wss, active_workspace: aw}} <- app,
         %{tabs: tabs, active_tab: at} <- Enum.find(wss, &(&1.id == aw)),
         %{layout: layout} <- Enum.find(tabs, &(&1.id == at)) do
      Layout.pane_ids(layout)
    else
      _ -> []
    end
  end

  # the active tab's kitty placements, one Facts read per pane (hidden tabs have none)
  defp graphics(ids) do
    for id <- ids, g = Facts.graphics(id), g != [], into: %{}, do: {id, g}
  end

  # scrolled panes (scrollbar), the selection's and copy mode's pane (offset), one Facts
  # read per pane
  defp facts(state, ids) do
    sel = state.pointer.selection
    live = for %{pane: id} <- [sel, state.copy], do: id

    case Guard.run_twice(PointerIo, :scene_facts, [ids, live], guard()) do
      {:ok, %{} = facts} -> facts
      _failed -> %{}
    end
  end

  # one recompute when pruning changed the pointer (rare: close or resize under a selection)
  defp pruned(state, app, scene) do
    case Guard.run_twice(Pointer, :prune, [state.pointer, state.last_scene, scene], guard()) do
      {:ok, %Pointer{} = p} when p != state.pointer ->
        state = %{state | pointer: p}

        case view(state, app) do
          {:ok, scene} -> {state, scene}
          _failed -> {state, drop_stale(scene, p)}
        end

      _same_or_failed ->
        {state, scene}
    end
  end

  # recompute failed: keep no selection/hover overlay the pruned pointer no longer owns
  defp drop_stale(scene, p) do
    panes =
      for pane <- scene.panes do
        keep = fn
          :selection -> p.selection != nil and p.selection.pane == pane.id
          :link_hover -> p.hover != nil and p.hover.pane == pane.id
          _other -> true
        end

        %{pane | overlays: Enum.filter(pane.overlays, &keep.(&1.kind))}
      end

    %{scene | panes: panes}
  end

  defp send_scene(%{last_scene: scene} = state, scene), do: state

  defp send_scene(state, scene) do
    send(state.client, {:scene, scene})
    %{state | last_scene: scene}
  end

  # inline transport: full rows and cursors in the scene (M16 optimizes)
  defp fill(scene) do
    panes =
      Enum.map(scene.panes, fn pane ->
        case Rows.fetch(pane.id) do
          {_gen, rows, cursor} -> %{pane | rows: {:inline, indexed(rows)}, cursor: cursor}
          nil -> %{pane | rows: {:inline, []}, cursor: nil}
        end
      end)

    # with chrome focus (a prompt) the cursor is View's, never the pane's
    cursor = if scene.focus.chrome, do: scene.cursor, else: host(panes, scene.focus.pane)
    %{scene | panes: panes, cursor: cursor}
  end

  defp indexed(rows), do: rows |> Tuple.to_list() |> Enum.with_index(fn b, n -> {n, b} end)

  defp host(panes, focus) do
    case Enum.find(panes, &(&1.id == focus)) do
      nil -> nil
      pane -> host_cursor(pane)
    end
  end

  defp host_cursor(%{cursor: %{visible: true} = c, rect: r}) when c.y < r.h and r.w > 0,
    do: %{x: r.x + min(c.x, r.w - 1), y: r.y + c.y, shape: c.shape}

  defp host_cursor(_pane), do: nil
end
