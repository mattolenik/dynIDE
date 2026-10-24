defmodule HerdrServer.Kernel.Fake.Keeper do
  @moduledoc """
  In-memory keeper with `Native.Keeper`'s API (allocates ids from 1). Resources are
  linked to it, so a restart wipes them.
  """
  use GenServer

  @behaviour HerdrServer.Kernel.Keeper

  alias HerdrServer.Kernel.Fake.{Pty, Vt}

  defstruct panes: %{}, next_id: 1, fail: nil, last_spec: nil

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl HerdrServer.Kernel.Keeper
  def open(spec), do: GenServer.call(__MODULE__, {:open, spec})

  @impl HerdrServer.Kernel.Keeper
  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})

  @impl HerdrServer.Kernel.Keeper
  def close(id), do: GenServer.call(__MODULE__, {:close, id})

  @impl HerdrServer.Kernel.Keeper
  def ids, do: GenServer.call(__MODULE__, :ids)

  @doc "Test hook: the next `open/1` returns `{:error, reason}`."
  def fail_next_open(reason), do: GenServer.call(__MODULE__, {:fail, reason})

  @doc "Test hook: the spec of the most recent successful `open/1`, or nil."
  def last_spec, do: GenServer.call(__MODULE__, :last_spec)

  @impl GenServer
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call({:open, _spec}, _from, %{fail: reason} = state) when reason != nil do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, reason}, %{state | fail: nil}}
  end

  def handle_call({:open, o}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    id = state.next_id
    {:ok, vt} = Vt.new(o.cols, o.rows, o.max_scrollback)
    if replay = Map.get(o, :replay), do: Vt.write_sync(vt, replay)
    {:ok, pty, os_pid} = Pty.spawn(vt, id, o.cmd, o.args, o.env, o.cwd, o.cols, o.rows)
    if o.subscriber, do: Pty.subscribe(pty, o.subscriber)
    res = %{vt: vt, pty: pty, os_pid: os_pid, cmd: [o.cmd | o.args]}

    {:reply, {:ok, id},
     %{state | panes: Map.put(state.panes, id, res), next_id: id + 1, last_spec: o}}
  end

  def handle_call(:last_spec, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.last_spec, state}
  end

  def handle_call({:fail, reason}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | fail: reason}}
  end

  def handle_call({:lookup, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Map.fetch(state.panes, id), state}
  end

  def handle_call({:close, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    case Map.pop(state.panes, id) do
      {nil, _} ->
        {:reply, :ok, state}

      {res, panes} ->
        GenServer.stop(res.pty)
        GenServer.stop(res.vt)
        {:reply, :ok, %{state | panes: panes}}
    end
  end

  def handle_call(:ids, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.panes |> Map.keys() |> Enum.sort(), state}
  end
end
