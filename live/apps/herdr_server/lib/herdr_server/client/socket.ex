defmodule HerdrServer.Client.Socket do
  @moduledoc """
  The client protocol's unix socket (`HerdrScene.Wire`): remote and socket clients attach
  here. Mode 0600, removed on stop; path rules and stale-socket handling are
  `Api.SocketPath.prepare/1`'s. A refused path or a failed listen runs this VM without a
  client socket (logged), never failing app start.

  An acceptor process (linked; 1 s accept timeout and a remote call per loop, so a reload
  moves it onto new code) hands each connection to a short-lived handshake process: it
  reads `{:auth, token}` then `{:attach, info}` within 5 s (else closes), compares the
  token in constant time, validates the attach (plain data, `Wire.validate_client_frame/1`,
  protocol version, session name per R16) and answers `{:refused, why}` plus a close on
  failure. A session target is served by a `Client.Remote` conn: the one registered under
  `client_id` (a resume) or a new one under `Client.Remote.Supervisor`; so is a pane target
  (R17), refused with `"no pane p<id>"` when the pane has no rows.

  Handoff (R11): adopted `client/` entries are claimed by
  `Client.Remote.Supervisor.adopt_all/0` at application start, not here: THAW restarts
  this child from inside a `Handoff.Link` callback, so `init` must never call the Link.
  During a handoff (`Client.Remote.handoff?/0`) a handshake closes its socket instead of
  serving it, so no conn starts or resumes after the freeze; the client reconnects to the
  next VM.

  Options: `path`, `token_path` (defaults from `Wire.paths/2` of the environment).
  """
  use GenServer

  require Logger

  alias HerdrScene.Wire
  alias HerdrServer.Api.{Ids, Listener, SocketPath}
  alias HerdrServer.Client.Remote
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Persist.{Disk, Schema}

  @handshake_ms 5000
  # auth and attach frames are small; nothing bigger is read before the token is checked
  @handshake_frame 65_536

  defstruct path: nil, listen: nil, acceptor: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The token at `token_path`, created once (32 random bytes, hex, mode 0600). A file that
  is empty after trimming counts as missing: it is replaced (once; a second empty one
  raises), so a truncated token never authenticates anyone.
  """
  @spec token(Path.t()) :: binary
  def token(token_path), do: token(token_path, 2)

  defp token(path, tries) do
    case File.read(path) do
      {:ok, t} when t != "" ->
        case String.trim(t) do
          "" ->
            retry_token(path, tries)

          trimmed ->
            _ = File.chmod(path, 0o600)
            trimmed
        end

      {:ok, ""} ->
        retry_token(path, tries)

      {:error, :enoent} ->
        create_token(path, tries)

      {:error, why} ->
        raise File.Error, reason: why, action: "read token", path: path
    end
  end

  defp retry_token(path, tries) when tries > 1 do
    _ = File.rm(path)
    create_token(path, tries - 1)
  end

  defp retry_token(path, _tries),
    do: raise(File.Error, reason: :empty, action: "read token", path: path)

  # Complete before it is visible: a 0600 temp file, then a hard link that fails when a
  # racing creator got there first (whose token then wins).
  defp create_token(path, tries) do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    tmp = "#{path}.#{System.unique_integer([:positive])}.#{System.pid()}.tmp"

    try do
      File.write!(tmp, "", [:exclusive])
      File.chmod!(tmp, 0o600)
      File.write!(tmp, hex)

      case File.ln(tmp, path) do
        :ok -> hex
        {:error, :eexist} -> token(path, tries)
        {:error, why} -> raise File.Error, reason: why, action: "create token", path: path
      end
    after
      _ = File.rm(tmp)
    end
  end

  @doc "This instance's session name (R16)."
  @spec session_name() :: binary
  def session_name do
    raw = Application.get_env(:herdr_server, HerdrServer.Persist, [])[:name]
    Disk.resolve_name(raw || System.get_env("HERDR_LIVE_SESSION"))
  end

  @doc "The listening path, or nil when no client socket runs."
  @spec path() :: Path.t() | nil
  def path do
    GenServer.call(__MODULE__, :path)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    paths = Wire.paths(System.get_env(), System.user_home!())
    path = Keyword.get(opts, :path, paths.socket)
    token_path = Keyword.get(opts, :token_path, paths.token)

    with :ok <- SocketPath.prepare(path),
         {:ok, token} <- read_token(token_path),
         {:ok, listen} <- listen(path) do
      # connecting needs write permission on Linux; macOS ignores socket modes
      _ = File.chmod(path, 0o600)
      Process.flag(:trap_exit, true)
      ctx = %{token: token, session: session_name()}
      acceptor = spawn_link(__MODULE__, :accept, [listen, ctx])
      {:ok, %__MODULE__{path: path, listen: listen, acceptor: acceptor}}
    else
      {:error, why} ->
        Logger.warning("no client socket at #{path}: #{inspect(why)}")
        :ignore
    end
  end

  defp read_token(path) do
    {:ok, token(path)}
  rescue
    e in File.Error -> {:error, Exception.message(e)}
  end

  defp listen(path), do: :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | socket_opts()])

  @doc false
  # accepted (and adopted) sockets get these; a write blocked 5 s closes that connection
  @spec socket_opts() :: [:gen_tcp.option()]
  def socket_opts,
    do: [:binary, packet: :raw, active: false, send_timeout: 5000, send_timeout_close: true]

  @impl true
  def handle_call(:path, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.path, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if pid == state.acceptor, do: {:stop, reason, state}, else: {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  @impl true
  def terminate(_reason, state) do
    state = Map.merge(%__MODULE__{}, state)
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  @doc false
  @spec accept(:gen_tcp.socket(), map) :: :ok
  def accept(listen, ctx) do
    case :gen_tcp.accept(listen, 1000) do
      {:ok, s} ->
        pid = spawn(__MODULE__, :handshake, [ctx])

        case :gen_tcp.controlling_process(s, pid) do
          :ok -> send(pid, {:socket, s})
          {:error, _} -> :gen_tcp.close(s)
        end

        __MODULE__.accept(listen, ctx)

      {:error, :timeout} ->
        __MODULE__.accept(listen, ctx)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Listener.accept_failed(reason)
        Process.sleep(100)
        __MODULE__.accept(listen, ctx)
    end
  end

  @doc false
  @spec handshake(map) :: :ok
  def handshake(ctx) do
    receive do
      {:socket, s} ->
        deadline = System.monotonic_time(:millisecond) + @handshake_ms

        with {:ok, auth, buf} <- frame(s, "", deadline),
             :ok <- auth(auth, ctx.token),
             {:ok, attach, buf} <- frame(s, buf, deadline),
             {:ok, info} <- attach(attach, ctx.session),
             :ok <- target(info.target),
             false <- Remote.handoff?() do
          serve(s, info, buf)
        else
          {:refused, _} = r ->
            refuse(s, r)

          _closed_or_garbage ->
            :gen_tcp.close(s)
        end
    after
      @handshake_ms -> :ok
    end

    :ok
  end

  # the next frame (at most @handshake_frame; what follows it stays in the buffer for the
  # conn, which applies the client limit), or an error
  defp frame(s, buf, deadline) do
    case buf do
      <<len::32-big, _::binary>> when len > @handshake_frame ->
        {:error, :too_large}

      <<len::32-big, etf::binary-size(len), rest::binary>> ->
        case Wire.decode(<<len::32-big, etf::binary>>, @handshake_frame) do
          {:ok, [term], ""} -> {:ok, term, rest}
          other -> other
        end

      _partial ->
        left = deadline - System.monotonic_time(:millisecond)

        with true <- left > 0,
             {:ok, data} <- :gen_tcp.recv(s, 0, left),
             do: frame(s, buf <> data, deadline),
             else: (_ -> :closed)
    end
  end

  # an empty server token (never created by token/1) authenticates no one
  defp auth(_frame, ""), do: {:refused, "bad token"}

  defp auth({:auth, t}, token) when is_binary(t) and byte_size(t) == byte_size(token) do
    if :crypto.hash_equals(t, token), do: :ok, else: {:refused, "bad token"}
  end

  defp auth(_other, _token), do: {:refused, "bad token"}

  defp attach(frame, session) do
    with true <- Schema.plain?(frame) || {:refused, "attach: not plain data"},
         {:attach, info} <- frame,
         :ok <- valid(Wire.validate_client_frame(frame)) do
      cond do
        info.version != Wire.version() ->
          {:refused, "protocol version"}

        info.session not in [nil, session] ->
          {:refused, "no session #{info.session} here (this server runs #{session})"}

        true ->
          {:ok, info}
      end
    else
      {:refused, _} = r -> r
      _ -> {:refused, "expected attach"}
    end
  end

  defp target(:session), do: :ok

  defp target({:pane, id, _mode}),
    do: if(Rows.gen(id), do: :ok, else: {:refused, "no pane #{Ids.pane(id)}"})

  defp valid(:ok), do: :ok
  defp valid({:error, why}), do: {:refused, why}

  # a resume (a conn under this client_id), else a new conn; one that just stopped
  # (grace expiry) or raced us to the id is retried once
  defp serve(s, info, buf, tries \\ 2) do
    pid =
      case Registry.lookup(Remote.Registry, info.client_id) do
        [{pid, _}] -> pid
        [] -> start_conn(info)
      end

    with pid when is_pid(pid) <- pid,
         :ok <- :gen_tcp.controlling_process(s, pid),
         :ok <- Remote.resume(pid, s, info, buf) do
      :ok
    else
      {:refused, _} = r -> refuse(s, r)
      # the conn closed it: a handoff is under way, or another target's client_id
      r when r in [:handoff, :refused] -> :ok
      _ when tries > 1 -> serve(s, info, buf, tries - 1)
      _ -> :gen_tcp.close(s)
    end
  end

  defp start_conn(info) do
    case Remote.Supervisor.start_conn(info) do
      {:ok, pid} -> pid
      :ignore -> :retry
      {:error, why} -> {:refused, "attach failed: #{inspect(why)}"}
    end
  end

  defp refuse(s, {:refused, why}) do
    HerdrReload.Telemetry.event(:client_refused, reason: why)
    _ = :gen_tcp.send(s, Wire.encode({:refused, why}))
    :gen_tcp.close(s)
  end
end
