defmodule HerdrServer.Control do
  @moduledoc """
  Local control socket for `herdr-live rollback [n]`: a unix socket at `path/0`
  (`$HERDR_LIVE_CONTROL`, else `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/control.sock`,
  directory mode 0700), removed on stop. Started only when `HerdrReload` is enabled.

  Line protocol, one command per connection: `rollback [N]\\n` (N >= 1, default 1) replies
  `ok <batch ids>\\n` (`ok none\\n` when nothing was rolled back) or `error <msg>\\n`.
  Ruling: a stopgap until M12's API; local only, never a network listener.

  If another live instance answers on the path, or the socket cannot be opened, this
  one runs without a control socket (logged).
  Options: `path`, `server` (the `HerdrReload.Server`, default its registered name).
  """
  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The control socket path."
  @spec path() :: Path.t()
  def path do
    # empty counts as unset, like the launcher's ${VAR:-default}
    env("HERDR_LIVE_CONTROL") ||
      Path.join([
        env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state"),
        "herdr-live",
        "control.sock"
      ])
  end

  defp env(var), do: if(System.get_env(var) in [nil, ""], do: nil, else: System.get_env(var))

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &path/0)
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.chmod(Path.dirname(path), 0o700)

    cond do
      # sun_path is 104 bytes on macOS, 108 on Linux; longer paths raise badarg
      byte_size(path) > 103 ->
        Logger.warning("control socket path too long (#{byte_size(path)} bytes): #{path}")
        :ignore

      live?(path) ->
        Logger.warning("control socket #{path} is in use; running without one")
        :ignore

      true ->
        listen(path, Keyword.get(opts, :server, HerdrReload.Server))
    end
  end

  defp listen(path, server) do
    _ = File.rm(path)

    case :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}]) do
      {:ok, listen} ->
        Process.flag(:trap_exit, true)
        me = self()
        spawn_link(fn -> accept(listen, me) end)
        {:ok, %{path: path, listen: listen, server: server}}

      {:error, reason} ->
        Logger.warning("control socket #{path} not started: #{inspect(reason)}")
        :ignore
    end
  end

  # the acceptor asks for the current server so tests can swap it
  @impl true
  def handle_call(:server, _from, state), do: {:reply, state.server, state}

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
    case HerdrReload.Server.rollback(GenServer.call(owner, :server), n) do
      {:ok, []} -> "ok none\n"
      {:ok, ids} -> "ok #{Enum.join(ids, " ")}\n"
    end
  catch
    :exit, reason -> "error rollback failed: #{inspect(reason) |> String.slice(0, 200)}\n"
  end
end
