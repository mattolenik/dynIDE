defmodule HerdrCli.Relay do
  @moduledoc """
  `herdr-live attach-relay [<session>]`: stdio <-> the local client socket, run on the server
  host over ssh by `herdr-live attach <host>`. The relay reads the client token itself and
  sends `{:auth, token}` as the first frame (R2), so the token never leaves the host.

  Bytes are relayed raw: the framing is the client's and the server's business. Exit 0 when
  the socket closes or stdin reaches eof, 1 when there is no token or no socket. The
  session argument is ignored here: the client names it in its attach frame (R16). When the
  stdout reader goes away (ssh dropped) the relay exits 0 too.
  """

  alias HerdrScene.Wire

  @usage "usage: herdr-live attach-relay [<session>]\n"
  @drain_ms 5_000

  @doc "The usage text."
  @spec usage() :: String.t()
  def usage, do: @usage

  @spec run(%{optional(String.t()) => String.t()}) :: 0 | 1
  def run(env) do
    paths = Wire.paths(env, Map.get(env, "HOME", ""))

    with {:ok, token} <- token(paths.token),
         {:ok, socket} <- connect(paths.socket),
         :ok <- auth(socket, token) do
      # the fd port dies with :epipe when the stdout reader goes away: an exit, not a crash
      Process.flag(:trap_exit, true)
      pump(socket, Port.open({:fd, 0, 1}, [:binary, :stream, :eof]))
    else
      {:error, text} ->
        :file.write(:standard_error, ["herdr-live: ", text, ?\n])
        1
    end
  end

  defp auth(socket, token) do
    case :gen_tcp.send(socket, Wire.encode({:auth, token})) do
      :ok -> :ok
      {:error, r} -> {:error, "server closed the connection: #{inspect(r)}"}
    end
  end

  defp token(path) do
    with {:ok, t} <- File.read(path),
         t when t != "" <- String.trim(t) do
      {:ok, t}
    else
      _ -> {:error, "no client token at #{path} (is herdr-live running?)"}
    end
  end

  defp connect(path) do
    # a wedged server must not block the relay forever
    opts = [:binary, packet: :raw, active: :once, send_timeout: 30_000, send_timeout_close: true]

    case :gen_tcp.connect({:local, path}, 0, opts) do
      {:ok, socket} -> {:ok, socket}
      {:error, r} -> {:error, "cannot connect to #{path}: #{inspect(r)}"}
    end
  end

  @doc """
  Copies stdin (`port`) to `socket` and socket to the port until either closes. A slow
  reader backs up into the server's writes: the fd driver marks the port busy past its
  8 KiB high watermark and `Port.command/2` suspends until it drains, so the socket is
  not read meanwhile. Pending output is flushed before returning.
  """
  @spec pump(port(), port()) :: 0
  def pump(socket, port) do
    receive do
      {:tcp, ^socket, data} ->
        if out(port, data) do
          _ = :inet.setopts(socket, active: :once)
          pump(socket, port)
        else
          :gen_tcp.close(socket)
          0
        end

      {:tcp_closed, ^socket} ->
        drain(port)

      {:tcp_error, ^socket, _} ->
        drain(port)

      {^port, {:data, data}} ->
        case :gen_tcp.send(socket, data) do
          :ok -> pump(socket, port)
          {:error, _} -> drain(port)
        end

      {^port, :eof} ->
        :gen_tcp.close(socket)
        0

      {:EXIT, ^port, _} ->
        :gen_tcp.close(socket)
        0
    end
  end

  # false once the port died (stdout reader gone) with its EXIT still queued behind this data
  defp out(port, data) do
    Port.command(port, data)
  rescue
    ArgumentError -> false
  end

  defp drain(port), do: drain(port, System.monotonic_time(:millisecond) + @drain_ms)

  defp drain(port, deadline) do
    case Port.info(port, :queue_size) do
      {:queue_size, n} when n > 0 ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          drain(port, deadline)
        else
          0
        end

      _ ->
        0
    end
  end
end
