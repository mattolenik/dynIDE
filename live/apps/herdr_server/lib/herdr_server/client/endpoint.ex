defmodule HerdrServer.Client.Endpoint do
  @moduledoc """
  Client discovery (contract decision 5): registered as `HerdrScene.Protocol.endpoint()`.
  `{:attach, info}` starts a `Client.Session` and replies
  `{:ok, session_pid, %{rows: {HerdrServer.Pane.Rows, :fetch, []}}}` or `{:error, reasons}`.
  A client pid that re-attaches gets its mirrored presentation state back
  (`HerdrServer.Mirror.client/1`, passed to the session as `info.mirrored`).

  A session that stops normally deletes its client's mirror entry; one that crashes keeps
  it for a re-attach. The endpoint monitors sessions: on a crash it logs a `crash` event
  and, while the client lives, monitors the client too, deleting the entry when the client
  exits without re-attaching. `init` sweeps entries of dead client pids.
  """
  use GenServer

  alias HerdrScene.Protocol
  alias HerdrServer.Client.Supervisor, as: Sessions

  alias HerdrServer.Mirror

  # sessions: session monitor ref -> client pid; orphans: client monitor ref -> client pid
  defstruct sessions: %{}, orphans: %{}

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: Protocol.endpoint())

  @impl true
  def init(:ok) do
    for pid <- Mirror.clients(), not Process.alive?(pid), do: Mirror.delete({:client, pid})
    {:ok, %__MODULE__{}}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  @impl true
  def handle_call({:attach, info} = msg, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    {reply, state} =
      with :ok <- Protocol.validate_client_msg(msg),
           info = Map.put(info, :mirrored, Mirror.client(info.client)),
           {:ok, pid} <- Sessions.start_session(info) do
        state = forget_orphans(state, info.client)
        ref = Process.monitor(pid)
        state = %{state | sessions: Map.put(state.sessions, ref, info.client)}
        {{:ok, pid, %{rows: {HerdrServer.Pane.Rows, :fetch, []}}}, state}
      else
        {:error, why} when is_binary(why) -> {{:error, [why]}, state}
        other -> {{:error, ["attach failed: #{inspect(other)}"]}, state}
      end

    {:reply, reply, state}
  end

  def handle_call(other, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, ["unknown request #{inspect(other)}"]}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)

    case {Map.pop(state.sessions, ref), Map.pop(state.orphans, ref)} do
      {{nil, _}, {nil, _}} ->
        {:noreply, state}

      {{client, sessions}, _} when client != nil ->
        state = %{state | sessions: sessions}
        {:noreply, if(reason == :normal, do: state, else: session_crashed(state, client, reason))}

      {_, {client, orphans}} ->
        state = %{state | orphans: orphans}
        if client in Map.values(state.sessions), do: :ok, else: Mirror.delete({:client, client})
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  defp session_crashed(state, client, reason) do
    if not match?(r when r == :shutdown or (is_tuple(r) and elem(r, 0) == :shutdown), reason),
      do:
        HerdrReload.Telemetry.event(:crash,
          proc: :session,
          action: :none,
          reason: inspect(reason)
        )

    if Process.alive?(client) and client not in Map.values(state.orphans) do
      %{state | orphans: Map.put(state.orphans, Process.monitor(client), client)}
    else
      if not Process.alive?(client), do: Mirror.delete({:client, client})
      state
    end
  end

  defp forget_orphans(state, client) do
    {gone, kept} = Enum.split_with(state.orphans, fn {_ref, c} -> c == client end)
    for {ref, _} <- gone, do: Process.demonitor(ref, [:flush])
    %{state | orphans: Map.new(kept)}
  end
end
