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
  @max_write 1_048_576
  @signals %{hup: 1, int: 2, kill: 9, term: 15}

  defstruct id: nil,
            vt: nil,
            subs: [],
            hidden: false,
            gen: 0,
            last_sent: 0,
            timer: nil,
            backpressure: false,
            reject_after: nil,
            reject_with: :backpressure,
            reject_next: 0,
            close_after: nil,
            writes: [],
            closed: false,
            cwd: nil,
            os_pid: nil,
            activity: 0,
            foreground: :default

  @impl HerdrServer.Kernel.Pty
  def spawn(vt, id, _cmd, _args, _env, cwd, _cols, _rows) do
    os_pid = System.unique_integer([:positive])
    {:ok, pty} = GenServer.start_link(__MODULE__, {id, vt, cwd, os_pid})
    {:ok, pty, os_pid}
  end

  @doc "Test/bench hook: feed bytes as program output. Never blocks on the vt."
  def output(pty, bin), do: GenServer.cast(pty, {:output, bin})

  @doc """
  Test hook: sends a kernel event to the subscribers with this pty's id inserted after
  the tag (`{:title, raw}` -> `{:title, id, raw}`, `{:bell}` -> `{:bell, id}`).
  """
  def emit(pty, event) when is_tuple(event), do: GenServer.cast(pty, {:emit, event})

  @impl HerdrServer.Kernel.Pty
  def write(pty, data) do
    if IO.iodata_length(data) > @max_write,
      do: {:error, :too_large},
      else: GenServer.call(pty, {:write, data})
  end

  @doc """
  Test hook: while on, `write/2` drops input and returns `{:error, :backpressure}`.
  After `kill/2` (which sends `{:exit, id, {:signal, n}}` once) writes are `{:error, :closed}`.
  """
  def set_backpressure(pty, on?), do: GenServer.call(pty, {:backpressure, on?})

  @doc "Test hook: accept `k` more writes, reject the next one with backpressure, then accept."
  def backpressure_once_after(pty, k), do: GenServer.call(pty, {:reject_after, k, :backpressure})

  @doc "Test hook: like `backpressure_once_after/2`, but the rejected write is `{:error, reason}`."
  def fail_once_after(pty, k, reason), do: GenServer.call(pty, {:reject_after, k, reason})

  @doc "Test hook: reject the next `n` writes with backpressure, then accept."
  def backpressure_next(pty, n), do: GenServer.call(pty, {:reject_next, n})

  @doc "Test hook: accept `k` more writes, then answer `{:error, :closed}` (no exit event)."
  def close_after(pty, k), do: GenServer.call(pty, {:close_after, k})

  @doc "Test hook: the last 100 accepted writes, oldest first."
  def writes(pty), do: GenServer.call(pty, :writes)

  @impl HerdrServer.Kernel.Pty
  def resize(pty, cols, rows, cell_px), do: GenServer.call(pty, {:resize, cols, rows, cell_px})

  @impl HerdrServer.Kernel.Pty
  def kill(pty, signal), do: GenServer.cast(pty, {:kill, signal})

  @impl HerdrServer.Kernel.Pty
  def subscribe(pty, pid), do: GenServer.call(pty, {:subscribe, pid})

  @impl HerdrServer.Kernel.Pty
  def set_hidden(pty, hidden), do: GenServer.call(pty, {:hidden, hidden})

  @impl HerdrServer.Kernel.Pty
  def cwd(pty), do: GenServer.call(pty, :cwd)

  @doc "Test hook: what `cwd/1` reports from now on (the spawn cwd until set)."
  def set_cwd(pty, cwd) when is_binary(cwd) or is_nil(cwd),
    do: GenServer.call(pty, {:set_cwd, cwd})

  @impl HerdrServer.Kernel.Pty
  def info(pty), do: GenServer.call(pty, :info)

  @impl HerdrServer.Kernel.Pty
  def activity(pty), do: GenServer.call(pty, :activity)

  @impl HerdrServer.Kernel.Pty
  def foreground_pgid(pty) do
    case foreground_job(pty) do
      %{pgid: pgid} -> pgid
      nil -> nil
    end
  end

  @impl HerdrServer.Kernel.Pty
  def foreground_job(pty), do: GenServer.call(pty, :foreground)

  @doc """
  Test hook: what `foreground_job/1` (and its pgid, `foreground_pgid/1`) report from now
  on. Until set: `%{pgid: os_pid, shell: true, processes: []}` with the spawn's os pid.
  """
  def set_foreground(pty, job) when is_map(job) or is_nil(job),
    do: GenServer.call(pty, {:set_foreground, job})

  @impl GenServer
  def init({id, vt, cwd, os_pid}) do
    {:ok, %__MODULE__{id: id, vt: vt, cwd: cwd, os_pid: os_pid, last_sent: now() - 1000}}
  end

  @impl GenServer
  def handle_cast({:output, bin}, state) do
    state = Map.merge(%__MODULE__{}, state)
    gen = state.gen + 1
    Vt.write(state.vt, bin, gen)
    activity = if bin == "", do: state.activity, else: state.activity + 1
    {:noreply, damage(%{state | gen: gen, activity: activity})}
  end

  def handle_cast({:emit, event}, state) do
    state = Map.merge(%__MODULE__{}, state)
    notify(state, Tuple.insert_at(event, 1, state.id))
    {:noreply, state}
  end

  def handle_cast({:kill, _signal}, %{closed: true} = state),
    do: {:noreply, Map.merge(%__MODULE__{}, state)}

  def handle_cast({:kill, signal}, state) do
    state = Map.merge(%__MODULE__{}, state)
    notify(state, {:exit, state.id, {:signal, Map.get(@signals, signal, signal)}})
    {:noreply, %{state | closed: true}}
  end

  @impl GenServer
  def handle_call({:write, _bin}, _from, %{closed: true} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:write, _bin}, _from, %{backpressure: true} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, :backpressure}, state}
  end

  def handle_call({:write, _bin}, _from, %{reject_after: 0} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, state.reject_with}, %{state | reject_after: nil}}
  end

  def handle_call({:write, _bin}, _from, %{close_after: 0} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, :closed}, %{state | closed: true}}
  end

  def handle_call({:write, _bin}, _from, %{reject_next: n} = state) when n > 0 do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, :backpressure}, %{state | reject_next: n - 1}}
  end

  def handle_call({:write, bin}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    left = if state.reject_after, do: state.reject_after - 1
    close = if state.close_after, do: state.close_after - 1
    log = Enum.take([IO.iodata_to_binary(bin) | state.writes], 100)
    state = %{state | reject_after: left, close_after: close, writes: log}
    {:noreply, state} = handle_cast({:output, IO.iodata_to_binary(bin)}, state)
    {:reply, :ok, state}
  end

  def handle_call({:reject_after, k, reason}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | reject_after: k, reject_with: reason}}
  end

  def handle_call(:cwd, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.cwd, state}
  end

  def handle_call(:activity, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.activity, state}
  end

  def handle_call(:foreground, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    job =
      case state.foreground do
        :default -> %{pgid: state.os_pid, shell: true, processes: []}
        job -> job
      end

    {:reply, job, state}
  end

  def handle_call({:set_foreground, job}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | foreground: job}}
  end

  def handle_call({:set_cwd, cwd}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | cwd: cwd}}
  end

  def handle_call({:reject_next, n}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | reject_next: n}}
  end

  def handle_call({:close_after, k}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | close_after: k}}
  end

  def handle_call(:writes, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Enum.reverse(state.writes), state}
  end

  def handle_call(:info, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    info = %{
      os_pid: 0,
      adopted: false,
      hidden: state.hidden,
      title: nil,
      pwd: nil,
      exited: if(state.closed, do: :unknown),
      start_time: nil
    }

    {:reply, info, state}
  end

  def handle_call({:backpressure, on?}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | backpressure: on?}}
  end

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
