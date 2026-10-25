defmodule HerdrCli.Relay do
  @moduledoc """
  `herdr-live attach-relay [<session>]`: stdio <-> the local client socket, run on the server
  host over ssh by `herdr-live attach <host>`. The relay reads the client token itself and
  sends `{:auth, token}` as the first frame (R2), so the token never leaves the host.

  Bytes are relayed raw: the framing is the client's and the server's business. Exit 0 when
  the socket closes or stdin reaches eof, 1 when there is no token or no socket. The
  session argument is ignored here: the client names it in its attach frame (R16).
  """

  alias HerdrScene.Wire

  @spec run(%{optional(String.t()) => String.t()}) :: 0 | 1
  def run(env) do
    paths = Wire.paths(env, Map.get(env, "HOME", ""))

    with {:ok, token} <- token(paths.token),
         {:ok, socket} <- connect(paths.socket) do
      :ok = :gen_tcp.send(socket, Wire.encode({:auth, token}))
      pump(socket, open_port({:fd, 0, 1}, [:binary, :stream, :eof]))
    else
      {:error, text} ->
        :file.write(:standard_error, ["herdr-live: ", text, ?\n])
        1
    end
  end

  defp token(path) do
    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> {:error, "no client token at #{path} (is herdr-live running?)"}
    end
  end

  defp connect(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: :raw, active: true]) do
      {:ok, socket} -> {:ok, socket}
      {:error, r} -> {:error, "cannot connect to #{path}: #{inspect(r)}"}
    end
  end

  @doc "Copies stdin (`port`) to `socket` and socket to the port until either closes."
  @spec pump(port(), port()) :: 0
  def pump(socket, port) do
    receive do
      {:tcp, ^socket, data} ->
        Port.command(port, data)
        pump(socket, port)

      {:tcp_closed, ^socket} ->
        0

      {:tcp_error, ^socket, _} ->
        0

      {^port, {:data, data}} ->
        case :gen_tcp.send(socket, data) do
          :ok ->
            pump(socket, port)

          {:error, _} ->
            0
        end

      {^port, :eof} ->
        :gen_tcp.close(socket)
        0
    end
  end

  defp open_port(name, opts), do: Port.open(name, opts)
end
