defmodule HerdrServer.Client.Endpoint do
  @moduledoc """
  Client discovery (contract decision 5): registered as `HerdrScene.Protocol.endpoint()`.
  `{:attach, info}` starts a `Client.Session` and replies
  `{:ok, session_pid, %{rows: {HerdrServer.Pane.Rows, :fetch, []}}}` or `{:error, reasons}`.
  A client pid that re-attaches gets its mirrored presentation state back
  (`HerdrServer.Mirror.client/1`, passed to the session as `info.mirrored`).
  """
  use GenServer

  alias HerdrScene.Protocol
  alias HerdrServer.Client.Supervisor, as: Sessions

  defstruct []

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: Protocol.endpoint())

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:attach, info} = msg, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    reply =
      with :ok <- Protocol.validate_client_msg(msg),
           info = Map.put(info, :mirrored, HerdrServer.Mirror.client(info.client)),
           {:ok, pid} <- Sessions.start_session(info) do
        {:ok, pid, %{rows: {HerdrServer.Pane.Rows, :fetch, []}}}
      else
        {:error, why} when is_binary(why) -> {:error, [why]}
        other -> {:error, ["attach failed: #{inspect(other)}"]}
      end

    {:reply, reply, state}
  end

  def handle_call(other, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {:error, ["unknown request #{inspect(other)}"]}, state}
  end
end
