defmodule HerdrServer.Native.Keeper do
  @moduledoc """
  Owns every kernel resource (vt and pty) and the pane-id table. Everything
  else refers to panes by id and reads the table from ETS (`lookup/1`).

  A bad spec or a raising NIF returns an error instead of crashing the Keeper:
  a crash would lose the table and SIGHUP every pane.
  """
  use GenServer

  require HerdrServer.Native.Vt
  alias HerdrServer.Native.{Pty, Vt}

  @table __MODULE__
  @escalate_ms 2000
  @keys [:cmd, :args, :env, :cwd, :cols, :rows, :max_scrollback, :subscriber]

  # closing: id => pty, kept after `close/1` until the SIGKILL escalation.
  defstruct next_id: 1, closing: %{}

  @type id :: pos_integer
  @typedoc "`max_scrollback` is in bytes (e.g. 10_000_000); cols and rows are in 1..65535."
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

  @doc """
  Creates the vt and pty for `spec` and returns the new pane id.
  `{:error, {:invalid_spec, key}}` for a missing or ill-typed key,
  `{:error, Pty.spawn_error()}` when the spawn fails, `{:error, {:raise, message}}`
  when a NIF raises.
  """
  @spec open(spec) :: {:ok, id} | {:error, term}
  def open(spec) do
    with :ok <- check(spec), do: GenServer.call(__MODULE__, {:open, spec})
  end

  @spec lookup(id) :: {:ok, %{vt: Vt.vt(), pty: Pty.pty(), os_pid: pos_integer}} | :error
  def lookup(id) do
    case :ets.lookup(@table, id) do
      [{^id, row}] -> {:ok, row}
      [] -> :error
    end
  end

  @doc """
  Sends SIGHUP and removes the pane from the table; SIGKILL follows after 2 s
  (a no-op if the child was already reaped). The exit event still follows.
  """
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

    with :ok <- check(spec), :ok <- start(id, spec) do
      {:reply, {:ok, id}, %{state | next_id: id + 1}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:close, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    case lookup(id) do
      {:ok, %{pty: pty}} ->
        Pty.kill(pty, :hup)
        :ets.delete(@table, id)
        Process.send_after(self(), {:escalate, id}, @escalate_ms)
        {:reply, :ok, %{state | closing: Map.put(state.closing, id, pty)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:escalate, id}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {pty, closing} = Map.pop(state.closing, id)
    if pty, do: Pty.kill(pty, :kill)
    {:noreply, %{state | closing: closing}}
  end

  def handle_info(_msg, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  defp start(id, spec) do
    with {:ok, vt} <- Vt.new(spec.cols, spec.rows, spec.max_scrollback),
         {:ok, pty, os_pid} <-
           Pty.spawn(vt, id, spec.cmd, spec.args, spec.env, spec.cwd, spec.cols, spec.rows) do
      :ets.insert(@table, {id, %{vt: vt, pty: pty, os_pid: os_pid}})
      if spec.subscriber, do: Pty.subscribe(pty, spec.subscriber)
      :ok
    end
  rescue
    # Narrow on purpose: NIF badargs (ArgumentError) and ghostty raises (ErlangError)
    # become errors; anything else is a Keeper bug and should crash. The dropped pty
    # handle SIGHUPs its child.
    e in [ArgumentError, ErlangError] ->
      :ets.delete(@table, id)
      {:error, {:raise, Exception.message(e)}}
  end

  defp check(spec) when is_map(spec) do
    case Enum.find(@keys, &(not (is_map_key(spec, &1) and valid?(&1, spec[&1])))) do
      nil -> :ok
      key -> {:error, {:invalid_spec, key}}
    end
  end

  defp check(_spec), do: {:error, {:invalid_spec, :spec}}

  defp valid?(:cmd, v), do: is_binary(v)
  defp valid?(:args, v), do: list_of?(v, &is_binary/1)
  defp valid?(:env, v), do: list_of?(v, &match?({k, x} when is_binary(k) and is_binary(x), &1))
  defp valid?(:cwd, v), do: is_binary(v) or is_nil(v)
  defp valid?(:max_scrollback, v), do: is_integer(v) and v >= 0
  defp valid?(:subscriber, v), do: is_pid(v) or is_nil(v)
  defp valid?(_size, v), do: Vt.is_size(v)

  defp list_of?(v, ok?), do: is_list(v) and not List.improper?(v) and Enum.all?(v, ok?)
end
