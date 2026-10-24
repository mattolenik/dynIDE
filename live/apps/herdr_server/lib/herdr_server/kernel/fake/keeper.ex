defmodule HerdrServer.Kernel.Fake.Keeper do
  @moduledoc "In-memory keeper. Resources are linked to it, so a restart wipes them."
  use GenServer

  @behaviour HerdrServer.Kernel.Keeper

  alias HerdrServer.Kernel.Fake.{Pty, Vt}

  defstruct panes: %{}

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl HerdrServer.Kernel.Keeper
  def open(pane_id, opts), do: GenServer.call(__MODULE__, {:open, pane_id, opts})

  @impl HerdrServer.Kernel.Keeper
  def lookup(pane_id), do: GenServer.call(__MODULE__, {:lookup, pane_id})

  @impl HerdrServer.Kernel.Keeper
  def close(pane_id), do: GenServer.call(__MODULE__, {:close, pane_id})

  @impl HerdrServer.Kernel.Keeper
  def pane_ids, do: GenServer.call(__MODULE__, :pane_ids)

  @impl GenServer
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call({:open, id, o}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    if Map.has_key?(state.panes, id) do
      {:reply, {:error, :already_open}, state}
    else
      {:ok, vt} = Vt.new(o.cols, o.rows, 0)
      {:ok, pty, os_pid} = Pty.spawn(id, vt, o.cmd, o.args, o.env, o.cwd, o.cols, o.rows)
      res = %{vt: vt, pty: pty, os_pid: os_pid}
      {:reply, {:ok, res}, %{state | panes: Map.put(state.panes, id, res)}}
    end
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

  def handle_call(:pane_ids, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Map.keys(state.panes), state}
  end
end
