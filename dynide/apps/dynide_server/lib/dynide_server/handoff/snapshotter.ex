defmodule DynideServer.Handoff.Snapshotter do
  @moduledoc """
  Every `snapshot_ms` (`config :dynide_server, DynideServer.Handoff`), sends the broker an
  UPDATE for each pane whose Vt gen, title, pwd, hidden flag or exit changed (ruling 5),
  so a `kill -9` restores terminals at most about one interval old. Per-tick cost is a
  gen read and `Pty.info` per pane plus a snapshot per changed pane. Not started
  without a broker.
  """
  use GenServer

  require Logger

  alias DynideServer.Handoff.{Link, State}
  alias DynideServer.Native.{Keeper, Pty, Vt}

  defstruct ms: 1000, paused: false, sent: %{}, last_tick_us: 0, last_bytes: 0

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stops ticking; returns after any tick in flight."
  @spec pause() :: :ok
  def pause, do: call(:pause)

  @spec resume() :: :ok
  def resume, do: call(:resume)

  @doc "Runs a tick now (async)."
  @spec tick() :: :ok
  def tick do
    if pid = GenServer.whereis(__MODULE__), do: send(pid, :now)
    :ok
  end

  @spec stats() :: %{last_tick_us: non_neg_integer, last_bytes: non_neg_integer}
  def stats, do: GenServer.call(__MODULE__, :stats)

  defp call(msg),
    do:
      if(GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, msg, :infinity), else: :ok)

  @impl true
  def init(_opts) do
    if Link.enabled?() do
      ms = Application.get_env(:dynide_server, DynideServer.Handoff, [])[:snapshot_ms] || 1000
      Process.send_after(self(), :tick, ms)
      {:ok, %__MODULE__{ms: ms}}
    else
      :ignore
    end
  end

  @impl true
  def handle_call(:pause, _from, state),
    do: {:reply, :ok, %{Map.merge(%__MODULE__{}, state) | paused: true}}

  # marks reset: what the broker holds now is the final state of an aborted handoff
  def handle_call(:resume, _from, state),
    do: {:reply, :ok, %{Map.merge(%__MODULE__{}, state) | paused: false, sent: %{}}}

  def handle_call(:stats, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Map.take(state, [:last_tick_us, :last_bytes]), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :tick, state.ms)
    {:noreply, if(state.paused, do: state, else: run(state))}
  end

  def handle_info(:now, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, if(state.paused, do: state, else: run(state))}
  end

  def handle_info(_msg, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  defp run(state) do
    t0 = System.monotonic_time(:microsecond)

    {sent, bytes} =
      Enum.reduce(Keeper.ids(), {%{}, 0}, fn id, {sent, bytes} ->
        case Keeper.lookup(id) do
          {:ok, row} -> snap(id, row, Map.get(state.sent, id), sent, bytes)
          :error -> {sent, bytes}
        end
      end)

    %{
      state
      | sent: sent,
        last_tick_us: System.monotonic_time(:microsecond) - t0,
        last_bytes: bytes
    }
  end

  # `last` is the mark last sent, or `{:failed, mark}` while encoding fails
  defp snap(id, row, last, sent, bytes) do
    mark = {Vt.gen(row.vt), Map.take(Pty.info(row.pty), [:title, :pwd, :hidden, :exited])}

    if mark == last do
      {Map.put(sent, id, mark), bytes}
    else
      blob = State.encode(State.build(id, row, []))
      :ok = Link.update("pane/#{id}", blob)
      {Map.put(sent, id, mark), bytes + byte_size(blob)}
    end
  rescue
    # ghostty refused the snapshot (e.g. an unfinished escape over 64 KiB): retry each
    # tick, warn once
    e in ErlangError ->
      if not match?({:failed, _}, last),
        do: Logger.warning("handoff snapshot of pane #{id} failing: #{Exception.message(e)}")

      {Map.put(sent, id, {:failed, with({:failed, p} <- last, do: p)}), bytes}
  end
end
