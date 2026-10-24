defmodule HerdrServer.Native.Keeper do
  @moduledoc """
  Owns every kernel resource (vt and pty) and the pane-id table. Everything
  else refers to panes by id and reads the table from ETS (`lookup/1`).
  """
  use GenServer

  alias HerdrServer.Native.{Pty, Vt}

  @table __MODULE__

  defstruct next_id: 1

  @type id :: pos_integer
  @type spec :: %{
          cmd: binary,
          args: [binary],
          env: [{binary, binary}],
          cwd: binary | nil,
          cols: pos_integer,
          rows: pos_integer,
          max_scrollback: non_neg_integer,
          subscriber: pid | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec open(spec) :: {:ok, id} | {:error, term}
  def open(spec), do: GenServer.call(__MODULE__, {:open, spec})

  @spec lookup(id) :: {:ok, %{vt: Vt.vt(), pty: Pty.pty(), os_pid: pos_integer}} | :error
  def lookup(id) do
    case :ets.lookup(@table, id) do
      [{^id, row}] -> {:ok, row}
      [] -> :error
    end
  end

  @spec close(id) :: :ok
  def close(id), do: GenServer.call(__MODULE__, {:close, id})

  @spec ids() :: [id]
  def ids, do: @table |> :ets.select([{{:"$1", :_}, [], [:"$1"]}]) |> Enum.sort()

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:open, spec}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    id = state.next_id

    with {:ok, vt} <- Vt.new(spec.cols, spec.rows, spec.max_scrollback),
         {:ok, pty, os_pid} <-
           Pty.spawn(vt, id, spec.cmd, spec.args, spec.env, spec.cwd, spec.cols, spec.rows) do
      :ets.insert(@table, {id, %{vt: vt, pty: pty, os_pid: os_pid}})
      if spec.subscriber, do: Pty.subscribe(pty, spec.subscriber)
      {:reply, {:ok, id}, %{state | next_id: id + 1}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:close, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    with {:ok, %{pty: pty}} <- lookup(id) do
      Pty.kill(pty, :hup)
      :ets.delete(@table, id)
    end

    {:reply, :ok, state}
  end
end
