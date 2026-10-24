defmodule HerdrServer.Client.Session do
  @moduledoc """
  One per attached client (`restart: :temporary`; a crash is a detach from the client's
  point of view). Owns the client's `Client.State`, computes its scene with `View.compute/2`
  (through `SafeApply`) and pushes `{:scene, scene}` only when it differs from the last one.

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
  `{:ack, seq}`, and re-pushes the scene (the status shows the mode). Non-key events go
  to `App.Store` with this client's size. The session monitors the Store and stops when it dies, so the client
  re-attaches to the fresh one.
  """
  use GenServer, restart: :temporary

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Keybinds, Store}
  alias HerdrServer.Client.{Keys, State}
  alias HerdrServer.Pane.Rows
  alias HerdrServer.{SafeApply, View}

  def start_link(info), do: GenServer.start_link(__MODULE__, info)

  @impl true
  def init(info) do
    {:ok, _} = Registry.register(HerdrServer.Client.Registry, :clients, nil)
    :ok = Store.subscribe(self())

    state = %State{
      kind: info.kind,
      transport: info.transport,
      size: Map.take(info.size, [:cols, :rows]),
      cell_px: info.cell_px,
      caps: info.caps,
      client: info.client,
      monitor: Process.monitor(info.client),
      store_monitor: Process.monitor(Store)
    }

    {:ok, state, {:continue, :attach}}
  end

  @impl true
  def handle_continue(:attach, state) do
    state = Map.merge(%State{}, state)
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
    scene = state.last_scene

    if scene != nil and Enum.any?(scene.panes, &(&1.id == id)),
      do: {:noreply, damaged(state, scene, id, gen)},
      else: {:noreply, state}
  end

  def handle_info({:input, from, seq, ev} = msg, state) do
    state = Map.merge(%State{}, state)

    state =
      case Protocol.validate_client_msg(msg) do
        :ok ->
          input(state, ev, from)

        {:error, why} ->
          send(state.client, {:notice, %{level: :warning, text: "input rejected: " <> why}})
          state
      end

    if is_pid(from), do: send(from, {:ack, seq})
    {:noreply, state}
  end

  def handle_info({:notice, n}, state) do
    state = Map.merge(%State{}, state)
    send(state.client, {:notice, n})
    {:noreply, state}
  end

  # the protocol's client -> server detach message, or the Store's {:detach} effect for an
  # event from this session
  def handle_info({:detach}, state) do
    state = Map.merge(%State{}, state)
    send(state.client, {:detached, :requested})
    {:stop, :normal, state}
  end

  # client gone, or Store restarted (its new app is unknown to us: the client re-attaches)
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    state = Map.merge(%State{}, state)

    if ref in [state.monitor, state.store_monitor],
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  # stale damage for closed panes, unknown messages: ignore
  def handle_info(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  # --- input ---

  defp input(state, {:resize, %{cols: c, rows: r} = m}, _from) do
    resized(%{state | size: %{cols: c, rows: r}, cell_px: m.cell_px})
  end

  defp input(%{keybinds: %{}} = state, {:key, _} = ev, from) do
    case SafeApply.run(Keys, :resolve, [Map.take(state, [:mode, :swallow]), state.keybinds, ev]) do
      {:ok, {%{mode: mode, swallow: swallow}, result}} ->
        keyed(%{state | mode: mode, swallow: swallow}, state.mode, result, from)

      # a broken resolver (failure or bad shape) still lets the client type
      other ->
        send(state.client, {:notice, %{level: :error, text: "keys failed: #{inspect(other)}"}})
        Store.event(ev, driving_size(state))
        state
    end
  end

  defp input(state, ev, _from) do
    Store.event(ev, driving_size(state))
    state
  end

  defp keyed(state, old_mode, result, from) do
    case result do
      {:forward, ev} -> if not fast_path(ev), do: Store.event(ev, driving_size(state))
      {:run, mfa} -> Store.run(mfa, driving_size(state))
      _consumed -> :ok
    end

    if state.mode == old_mode do
      state
    else
      if is_pid(from), do: send(from, {:input_mode, state.mode})
      push(state, Store.snapshot())
    end
  end

  defp driving_size(state), do: Map.put(state.size, :cell_px, state.cell_px)

  # Same check as an in-VM client (contract decision 6), for remote/GUI clients, after
  # `Client.Keys` forwarded the key (so this client's own mode allowed it). Releases go
  # through the Store.
  defp fast_path({:key, %{key: k, mods: m, event: e}} = ev) when e != :release do
    case :persistent_term.get(Protocol.fast_path_key(), nil) do
      %{passthrough: true, write: {mod, f, a}, intercept: i} ->
        # a failure in either call sends the event the slow path
        with {:ok, key} <- SafeApply.run(Keybinds, :normalize, [k, m]),
             false <- MapSet.member?(i, key),
             {:ok, :ok} <- SafeApply.run(mod, f, [ev | a]),
             do: true,
             else: (_ -> false)

      _ ->
        false
    end
  end

  defp fast_path(_ev), do: false

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
    state = %{state | keybinds: app.ui.keybinds}

    case SafeApply.run(View, :compute, [app, state]) do
      {:ok, scene} ->
        send_scene(state, if(state.transport == :inline, do: fill(scene), else: scene))

      {:failed, reason} ->
        send(state.client, {:notice, %{level: :error, text: "view failed: #{inspect(reason)}"}})
        state
    end
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

    %{scene | panes: panes, cursor: host(panes, scene.focus.pane)}
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
