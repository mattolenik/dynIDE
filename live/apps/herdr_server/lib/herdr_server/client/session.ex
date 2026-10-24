defmodule HerdrServer.Client.Session do
  @moduledoc """
  One per attached client (`restart: :temporary`; a crash is a detach from the client's
  point of view). Owns the client's `Client.State`, computes its scene with `View.compute/2`
  (through `SafeApply`) and pushes `{:scene, scene}` only when it differs from the last one.

  Pane damage is forwarded as `{:damage, id, gen}` (ref transport) or `{:rows, id, gen,
  rows}` with the pane's full rows (inline transport), only for panes in the last scene;
  damage to the focused pane also refreshes cursors. Client input is validated (server-
  internal events are refused with a warning notice), checked against the fast path, else
  sent to `App.Store`, and always acked.
  """
  use GenServer, restart: :temporary

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Keybinds, Store}
  alias HerdrServer.Client.State
  alias HerdrServer.Pane.{Rows, Server}
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
      monitor: Process.monitor(info.client)
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

    cond do
      scene == nil or not Enum.any?(scene.panes, &(&1.id == id)) ->
        {:noreply, state}

      scene.focus.pane == id ->
        forward(state, id, gen)
        {:noreply, send_scene(state, refresh_cursor(scene, id))}

      true ->
        forward(state, id, gen)
        {:noreply, state}
    end
  end

  def handle_info({:input, from, seq, ev} = msg, state) do
    state = Map.merge(%State{}, state)

    state =
      case Protocol.validate_client_msg(msg) do
        :ok ->
          input(state, ev)

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

  # the protocol's client -> server detach message
  def handle_info({:detach}, state) do
    state = Map.merge(%State{}, state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    state = Map.merge(%State{}, state)
    if ref == state.monitor, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  # stale damage for closed panes, unknown messages: ignore
  def handle_info(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  # --- input ---

  defp input(state, {:resize, %{cols: c, rows: r} = m}) do
    resized(%{state | size: %{cols: c, rows: r}, cell_px: m.cell_px})
  end

  defp input(state, ev) do
    if not fast_path(ev), do: Store.event(ev, state.size)
    state
  end

  # Same check as an in-VM client (contract decision 6), for remote/GUI clients. Releases
  # always go through the Store so `focus.swallow` applies.
  defp fast_path({:key, %{key: k, mods: m, event: e}} = ev) when e != :release do
    case :persistent_term.get(Protocol.fast_path_key(), nil) do
      %{passthrough: true, write: {mod, f, a}, intercept: i} ->
        not MapSet.member?(i, Keybinds.normalize(k, m)) and apply(mod, f, [ev | a]) == :ok

      _ ->
        false
    end
  end

  defp fast_path(_ev), do: false

  defp resized(state) do
    :ok = Store.event({:resize, Map.put(state.size, :cell_px, state.cell_px)}, state.size)
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

  defp forward(%{transport: :inline} = state, id, _gen) do
    case Rows.fetch(id) do
      {gen, rows} ->
        rows = rows |> Tuple.to_list() |> Enum.with_index(fn b, n -> {n, b} end)
        send(state.client, {:rows, id, gen, rows})

      nil ->
        :ok
    end
  end

  defp forward(state, id, gen), do: send(state.client, {:damage, id, gen})

  defp push(state, nil), do: state

  defp push(state, app) do
    case SafeApply.run(View, :compute, [app, state]) do
      {:ok, scene} ->
        send_scene(state, with_cursors(scene))

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

  # ponytail: one cursor call per pane per scene compute; cache cursors if pane counts grow
  defp with_cursors(scene) do
    panes = Enum.map(scene.panes, &%{&1 | cursor: Server.cursor(&1.id)})
    %{scene | panes: panes, cursor: host(panes, scene.focus.pane)}
  end

  # damage to one pane: only its cursor can have moved
  defp refresh_cursor(scene, id) do
    panes =
      Enum.map(scene.panes, &if(&1.id == id, do: %{&1 | cursor: Server.cursor(id)}, else: &1))

    %{scene | panes: panes, cursor: host(panes, scene.focus.pane)}
  end

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
