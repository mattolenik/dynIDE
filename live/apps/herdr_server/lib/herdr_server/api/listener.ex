defmodule HerdrServer.Api.Listener do
  @moduledoc """
  The API's unix socket (`HerdrServer.Api.SocketPath`): mode 0600, removed on stop.
  Local only, never a network listener.

  An acceptor process (linked) accepts connections; each one is served by an
  `HerdrServer.Api.Conn` process linked to this one. A conn crash only forgets that conn;
  the acceptor's exit stops the listener. Stopping closes every open connection.
  A path that `SocketPath.prepare/1` refuses, or a failed listen, makes this VM run
  without an API socket (logged), never failing app start.

  Moves with the primary across a handoff: `Handoff.Link` terminates this child after the
  freeze on PREPARE and restarts it on THAW.

  Options: `path` (default `SocketPath.path/0`), `reload_server` (default
  `App.Store.reload_server/0`), `rollback_timeout_ms` (default 30 s), `router` (default
  `HerdrServer.Api.Router`; tests swap it).
  """
  use GenServer

  require Logger

  alias HerdrServer.Api.{Conn, Router, SocketPath}
  alias HerdrServer.App.Store

  @max_line 1_048_576

  defstruct path: nil,
            listen: nil,
            acceptor: nil,
            conns: MapSet.new(),
            ctx: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Open connections (0 when no listener runs)."
  @spec conns() :: non_neg_integer()
  def conns do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :conns), else: 0
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &SocketPath.path/0)

    ctx = %{
      reload_server: Keyword.get_lazy(opts, :reload_server, &Store.reload_server/0),
      rollback_timeout_ms: Keyword.get(opts, :rollback_timeout_ms, 30_000),
      router: Keyword.get(opts, :router, Router)
    }

    case SocketPath.prepare(path) do
      :ok ->
        listen(path, ctx)

      {:error, why} ->
        Logger.warning("no api socket at #{path}: #{why}")
        :ignore
    end
  end

  # buffer: line mode truncates a longer line to the buffer size (Conn detects that)
  defp listen(path, ctx) do
    opts = [
      :binary,
      packet: :line,
      packet_size: @max_line,
      buffer: @max_line,
      active: false,
      ifaddr: {:local, path}
    ]

    case :gen_tcp.listen(0, opts) do
      {:ok, listen} ->
        # connecting needs write permission on Linux; macOS ignores socket modes
        _ = File.chmod(path, 0o600)
        Process.flag(:trap_exit, true)
        me = self()
        acceptor = spawn_link(fn -> accept(listen, me) end)
        {:ok, %__MODULE__{path: path, listen: listen, acceptor: acceptor, ctx: ctx}}

      {:error, reason} ->
        Logger.warning("no api socket at #{path}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_call(:conn, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    ctx = state.ctx
    conn = spawn_link(fn -> Conn.serve(ctx) end)
    conns = MapSet.put(state.conns, conn)
    HerdrReload.Telemetry.event(:api_connect, conns: MapSet.size(conns))
    {:reply, conn, %{state | conns: conns}}
  end

  def handle_call(:conns, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, MapSet.size(state.conns), state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)

    if pid == state.acceptor,
      do: {:stop, reason, state},
      else: {:noreply, %{state | conns: MapSet.delete(state.conns, pid)}}
  end

  @impl true
  def terminate(_reason, state) do
    state = Map.merge(%__MODULE__{}, state)
    Enum.each(state.conns, &Process.exit(&1, :kill))
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  defp accept(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, s} ->
        conn = GenServer.call(owner, :conn)

        case :gen_tcp.controlling_process(s, conn) do
          :ok -> send(conn, {:socket, s})
          {:error, _} -> :gen_tcp.close(s)
        end

        accept(listen, owner)

      {:error, :closed} ->
        :ok
    end
  end
end
