defmodule HerdrServer.Persist.Writer do
  @moduledoc """
  Writes the session snapshot and pane scrollback to disk (`Persist.Disk`).

  Every `poll_ms` it captures the mirrored app plus pane facts (`Persist.Facts`,
  `Persist.Schema`) and writes only when the snapshot differs from the last one written.
  Every `scrollback_ms` it writes the history tail of each pane whose content generation
  changed since its last scrollback write (an `:alt_screen` pane keeps its old file) and
  prunes files of panes no longer in the app. Nothing is captured while a handoff is in
  progress (phase `:begin` or `:released`), or while the app is missing or has no panes.

  `terminate/2` (exits are trapped; this is the supervisor's last child, so it stops
  first while the Store and Keeper still run) writes once more from `App.Store.snapshot/0`
  (mirror on failure) with the scrollback of every pane, hidden ones included, unless a
  handoff is in progress.

  Kernel facts and capture run through `HerdrReload.Guard`: a failure skips that tick.
  Write failures log `persist_error` once per distinct reason until a write succeeds.
  `start_link/1` returns `:ignore` unless the config (`Disk.config/0` overridden by
  `opts`) has `enabled: true`.
  """

  use GenServer

  alias HerdrReload.{Guard, Telemetry}
  alias HerdrScene.Protocol
  alias HerdrServer.App.Store
  alias HerdrServer.{Layout, Mirror}
  alias HerdrServer.Persist.{Disk, Facts, Schema}

  @stop_snapshot_ms 1000

  defstruct cfg: nil,
            last_facts: %{},
            last_written: nil,
            sb_gens: %{},
            error: nil,
            stats: %{writes: 0, skipped: 0, last_us: 0, last_bytes: 0, scrollback_writes: 0}

  @type stats :: %{
          writes: non_neg_integer,
          skipped: non_neg_integer,
          last_us: non_neg_integer,
          last_bytes: non_neg_integer,
          scrollback_writes: non_neg_integer
        }

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Writes the snapshot and changed scrollback now."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @spec stats() :: stats
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(opts) do
    cfg = Map.merge(Disk.config(), Map.new(opts))

    if cfg.enabled do
      Process.flag(:trap_exit, true)
      Disk.sweep_tmp(cfg)
      Process.send_after(self(), :poll, cfg.poll_ms)
      Process.send_after(self(), :scrollback, cfg.scrollback_ms)
      {:ok, %__MODULE__{cfg: cfg}}
    else
      :ignore
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = state |> write_layout(Mirror.app()) |> write_scrollback(Mirror.app(), :changed)
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :poll, state.cfg.poll_ms)
    {:noreply, write_layout(state, Mirror.app())}
  end

  def handle_info(:scrollback, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :scrollback, state.cfg.scrollback_ms)
    {:noreply, write_scrollback(state, Mirror.app(), :changed)}
  end

  # trapped exits of anything but the parent (handled by GenServer) are not ours to act on
  def handle_info(_msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = Map.merge(%__MODULE__{}, state)
    app = store_app() || Mirror.app()
    state |> write_layout(app) |> write_scrollback(app, :all)
    :ok
  end

  defp store_app do
    GenServer.call(Store, :snapshot, @stop_snapshot_ms)
  catch
    :exit, _ -> nil
  end

  # --- snapshot ---

  defp write_layout(state, app) do
    if capturable?(app), do: capture_and_write(state, app), else: skipped(state)
  end

  defp capturable?(app) do
    :persistent_term.get(Protocol.handoff_key(), nil) not in [:begin, :released] and
      is_map(app) and map_size(app.session.panes) > 0
  end

  defp capture_and_write(state, app) do
    with {:ok, facts} <- guard(Facts, :collect, [app, state.last_facts]),
         {:ok, snap} <- guard(Schema, :capture, [app, facts]) do
      state = %{state | last_facts: facts}
      if snap == state.last_written, do: skipped(state), else: write(state, snap)
    else
      {:failed, failure} -> state |> error(:capture, Guard.message(failure)) |> skipped()
    end
  end

  defp write(state, snap) do
    t0 = System.monotonic_time(:microsecond)

    case Disk.write(state.cfg, snap) do
      :ok ->
        us = System.monotonic_time(:microsecond) - t0
        bytes = file_size(Disk.session_path(state.cfg))
        Telemetry.event(:persist_write, panes: map_size(snap.panes), bytes: bytes, us: us)

        stats = %{
          state.stats
          | writes: state.stats.writes + 1,
            last_us: us,
            last_bytes: bytes
        }

        %{state | last_written: snap, error: nil, stats: stats}

      {:error, reason} ->
        state |> error(:write, reason) |> skipped()
    end
  end

  defp skipped(state), do: update_in(state.stats.skipped, &(&1 + 1))

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  # --- scrollback ---

  defp write_scrollback(state, app, which) do
    if capturable?(app) and state.cfg.scrollback_rows > 0,
      do: scrollback_round(state, app, which),
      else: state
  end

  defp scrollback_round(state, app, which) do
    t0 = System.monotonic_time(:microsecond)
    ids = Map.keys(app.session.panes)

    cols =
      case guard(__MODULE__, :pane_cols, [app]) do
        {:ok, c} -> c
        {:failed, _} -> %{}
      end

    {state, written} =
      Enum.reduce(ids, {state, []}, fn id, acc -> pane_scrollback(acc, id, cols, app, which) end)

    Disk.prune_scrollback(state.cfg, ids)
    state = %{state | sb_gens: Map.take(state.sb_gens, ids)}

    if written == [] do
      state
    else
      Telemetry.event(:persist_write,
        kind: :scrollback,
        panes: length(written),
        bytes: Enum.sum(written),
        us: System.monotonic_time(:microsecond) - t0
      )

      update_in(state.stats.scrollback_writes, &(&1 + 1))
    end
  end

  defp pane_scrollback({state, written} = acc, id, cols, app, which) do
    gen = Facts.gen(id)

    if which == :all or gen != Map.get(state.sb_gens, id) do
      tail = guard(Facts, :tail, [id, state.cfg.scrollback_rows])
      store_tail(tail, acc, id, gen, Map.get(cols, id, app.session.area.w))
    else
      {state, written}
    end
  end

  defp store_tail({:ok, bin}, {state, written}, id, gen, w) when is_binary(bin) do
    case Disk.write_scrollback(state.cfg, id, bin, w) do
      :ok -> {put_gen(state, id, gen), [byte_size(bin) | written]}
      {:error, reason} -> {error(state, :write, reason), written}
    end
  end

  # the alternate screen has no history worth keeping: the old file stays
  defp store_tail({:ok, :alt_screen}, {state, written}, id, gen, _w),
    do: {put_gen(state, id, gen), written}

  defp store_tail({:ok, nil}, acc, _id, _gen, _w), do: acc

  defp store_tail({:failed, failure}, {state, written}, _id, _gen, _w),
    do: {error(state, :tail, Guard.message(failure)), written}

  defp put_gen(state, id, gen), do: %{state | sb_gens: Map.put(state.sb_gens, id, gen)}

  @doc false
  # content width of every pane in every tab, as `App.Actions` sizes them
  @spec pane_cols(map) :: %{pos_integer => pos_integer}
  def pane_cols(app) do
    area = app.session.area

    for ws <- app.session.workspaces,
        tab <- ws.tabs,
        %{id: id, rect: r} <- Layout.borders(Layout.panes(tab.layout, area), area),
        into: %{},
        do: {id, max(r.w, 1)}
  end

  # --- helpers ---

  defp guard(m, f, a), do: Guard.run(m, f, a, server: Store.reload_server())

  defp error(%{error: reason} = state, _op, reason), do: state

  defp error(state, op, reason) do
    Telemetry.event(:persist_error, op: op, reason: inspect(reason))
    %{state | error: reason}
  end
end
