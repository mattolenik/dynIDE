defmodule HerdrServer.Control do
  @moduledoc """
  Local control socket for `herdr-live rollback [n]`: a unix socket at `path/0`
  (`$HERDR_LIVE_CONTROL`, else `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/control.sock`),
  mode 0600, removed on stop. Started only when `HerdrReload` is enabled.

  Line protocol, one command per connection: `rollback [N]\\n` (N >= 1, default 1) replies
  `ok <batch ids>\\n` (`ok none\\n` when nothing was rolled back) or `error <msg>\\n`.
  Ruling: a stopgap until M12's API; local only, never a network listener.

  Only the default dir is created (0700 when created here; an existing dir keeps its
  mode); a custom path's dir must exist. A stale socket at the path is replaced; another
  live instance's socket, a non-socket file, a missing dir or an overlong path make this
  one run without a control socket (logged), never failing app start.
  Options: `path`, `server` (the `HerdrReload.Server`, default its registered name),
  `timeout_ms` (rollback call, default 30 s; `error timeout` past it).
  """
  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The control socket path."
  @spec path() :: Path.t()
  def path, do: env("HERDR_LIVE_CONTROL") || Path.join(default_dir(), "control.sock")

  # empty counts as unset, like the launcher's ${VAR:-default}
  defp default_dir do
    state = env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state, "herdr-live")
  end

  defp env(var), do: if(System.get_env(var) in [nil, ""], do: nil, else: System.get_env(var))

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &path/0)
    server = Keyword.get(opts, :server, HerdrReload.Server)
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    with :ok <- check_length(path),
         :ok <- ensure_dir(Path.dirname(path)),
         :ok <- free(path) do
      listen(path, %{server: server, timeout: timeout})
    else
      {:error, why} ->
        Logger.warning("no control socket at #{path}: #{why}")
        :ignore
    end
  end

  # sun_path is 104 bytes on macOS, 108 on Linux; longer paths raise badarg
  defp check_length(path) when byte_size(path) > 103, do: {:error, "path too long"}
  defp check_length(_), do: :ok

  # Only the default state dir is created, and chmodded 0700 only when created here: a
  # dir someone else made (or a symlink) keeps its mode.
  defp ensure_dir(dir) do
    case File.lstat(dir) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        if dir == default_dir(), do: create(dir), else: {:error, "#{dir} does not exist"}

      {:ok, %{type: type}} ->
        {:error, "#{dir} is a #{type}, not a directory"}

      {:error, _} = e ->
        errmsg(e)
    end
  end

  defp create(dir), do: errmsg(with(:ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)))

  # nothing at the path, or a socket nobody answers on (left by a killed VM): remove it.
  # Anything else is not ours to delete.
  defp free(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :other}} ->
        cond do
          live?(path) -> {:error, "in use by another instance"}
          socket?(path) -> errmsg(File.rm(path))
          true -> {:error, "a non-socket file is in the way"}
        end

      {:ok, %{type: type}} ->
        {:error, "a #{type} is in the way"}

      {:error, _} = e ->
        errmsg(e)
    end
  end

  # File.Stat folds sockets, fifos and devices into :other
  defp socket?(path), do: match?({_, 0}, System.cmd("test", ["-S", path]))

  defp errmsg({:error, r}) when is_atom(r), do: {:error, :file.format_error(r) |> to_string()}
  defp errmsg(other), do: other

  defp listen(path, state) do
    case :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}]) do
      {:ok, listen} ->
        # connecting needs write permission on Linux; macOS ignores socket modes
        _ = File.chmod(path, 0o600)
        Process.flag(:trap_exit, true)
        me = self()
        spawn_link(fn -> accept(listen, me) end)
        {:ok, Map.merge(state, %{path: path, listen: listen})}

      {:error, reason} ->
        Logger.warning("no control socket at #{path}: #{inspect(reason)}")
        :ignore
    end
  end

  # the acceptor asks for the current server so tests can swap it
  @impl true
  def handle_call(:server, _from, state), do: {:reply, {state.server, state.timeout}, state}

  @impl true
  def handle_info({:EXIT, _, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end

  defp live?(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 200) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      {:error, _} ->
        false
    end
  end

  # ponytail: one connection at a time; a slow client delays the next by up to 5 s
  defp accept(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, s} ->
        with {:ok, line} <- :gen_tcp.recv(s, 0, 5000),
             do: :gen_tcp.send(s, reply(String.trim(line), owner))

        :gen_tcp.close(s)
        accept(listen, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp reply("rollback", owner), do: rollback(1, owner)

  defp reply("rollback " <> n, owner) do
    case Integer.parse(n) do
      {n, ""} when n >= 1 -> rollback(n, owner)
      _ -> "error unknown command\n"
    end
  end

  defp reply(_, _), do: "error unknown command\n"

  defp rollback(n, owner) do
    {server, timeout} = GenServer.call(owner, :server)

    case call(server, n, timeout) do
      {:ok, []} -> "ok none\n"
      {:ok, ids} -> "ok #{Enum.join(ids, " ")}\n"
      {:error, msg} -> "error #{msg}\n"
    end
  end

  defp call(server, n, timeout) do
    HerdrReload.Server.rollback(server, n, timeout)
  catch
    :exit, {:timeout, _} -> {:error, "timeout"}
    :exit, reason -> {:error, "rollback failed: #{inspect(reason) |> String.slice(0, 200)}"}
  end
end
