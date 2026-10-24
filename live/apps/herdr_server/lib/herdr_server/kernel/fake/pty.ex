defmodule HerdrServer.Kernel.Fake.Pty do
  @moduledoc """
  Fake PTY: no OS process. Written bytes echo into the vt, `output/2` feeds
  program output. Damage is coalesced to one message per 4ms while output
  flows, immediate after quiet, suppressed while hidden.
  """
  use GenServer

  @behaviour HerdrServer.Kernel.Pty

  alias HerdrServer.Kernel.Fake.Vt

  @interval 4

  defstruct id: nil, vt: nil, subs: [], hidden: false, gen: 0, last_sent: 0, timer: nil

  @impl HerdrServer.Kernel.Pty
  def spawn(vt, _cmd, _args, _env, _cwd, _cols, _rows), do: start(nil, vt)

  @doc "Keeper entry point: like `spawn/7` but the pty knows its pane id (events carry it)."
  def spawn(id, vt, cmd, args, env, cwd, cols, rows) do
    _ = {cmd, args, env, cwd, cols, rows}
    start(id, vt)
  end

  defp start(id, vt) do
    {:ok, pty} = GenServer.start_link(__MODULE__, {id, vt})
    {:ok, pty, -System.unique_integer([:positive])}
  end

  @doc "Test/bench hook: feed bytes as program output. Never blocks on the vt."
  def output(pty, bin), do: GenServer.cast(pty, {:output, bin})

  @impl HerdrServer.Kernel.Pty
  def write(pty, bin), do: GenServer.cast(pty, {:output, bin})

  @impl HerdrServer.Kernel.Pty
  def resize(pty, cols, rows, cell_px), do: GenServer.call(pty, {:resize, cols, rows, cell_px})

  @impl HerdrServer.Kernel.Pty
  def kill(pty, signal), do: GenServer.cast(pty, {:kill, signal})

  @impl HerdrServer.Kernel.Pty
  def subscribe(pty, pid), do: GenServer.call(pty, {:subscribe, pid})

  @impl HerdrServer.Kernel.Pty
  def set_hidden(pty, hidden), do: GenServer.call(pty, {:hidden, hidden})

  @impl GenServer
  def init({id, vt}) do
    {:ok, %__MODULE__{id: id, vt: vt, last_sent: now() - 1000}}
  end

  @impl GenServer
  def handle_cast({:output, bin}, state) do
    state = Map.merge(%__MODULE__{}, state)
    gen = state.gen + 1
    Vt.write(state.vt, bin, gen)
    {:noreply, damage(%{state | gen: gen})}
  end

  def handle_cast({:kill, signal}, state) do
    state = Map.merge(%__MODULE__{}, state)
    notify(state, {:exit, state.id, {:signal, signal}})
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    Vt.force_full(state.vt)
    send(pid, {:damage, state.id, state.gen})
    {:reply, :ok, %{state | subs: Enum.uniq([pid | state.subs])}}
  end

  def handle_call({:hidden, false}, _from, %{hidden: true} = state) do
    state = Map.merge(%__MODULE__{}, state)
    notify(state, {:damage, state.id, state.gen})
    {:reply, :ok, %{state | hidden: false, last_sent: now()}}
  end

  def handle_call({:hidden, hidden}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | hidden: hidden}}
  end

  def handle_call({:resize, cols, rows, cell_px}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Vt.resize(state.vt, cols, rows, cell_px), state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    state = Map.merge(%__MODULE__{}, state)
    state = %{state | timer: nil}
    if state.hidden, do: {:noreply, state}, else: {:noreply, send_damage(state)}
  end

  defp damage(%{hidden: true} = state), do: state
  defp damage(%{timer: timer} = state) when timer != nil, do: state

  defp damage(state) do
    wait = @interval - (now() - state.last_sent)

    if wait <= 0,
      do: send_damage(state),
      else: %{state | timer: Process.send_after(self(), :flush, wait)}
  end

  defp send_damage(state) do
    notify(state, {:damage, state.id, state.gen})
    %{state | last_sent: now()}
  end

  defp notify(state, msg), do: Enum.each(state.subs, &send(&1, msg))
  defp now, do: System.monotonic_time(:millisecond)
end
