defmodule DynideCli.Client do
  @moduledoc """
  The API socket from the CLI side: path rule, connect with retry, one request
  line out, one reply line back, then (for subscriptions) further lines.

  `connect/2` retries `:enoent` and `:econnrefused` every 50 ms until `retry_ms`:
  during a graceful handoff the socket is gone for a few ms, and a call then must
  succeed rather than report "not running".
  """

  @retry_every_ms 50
  @attempt_ms 1000
  # socket packet size; longer lines arrive in pieces and are joined in recv_line
  @buffer 1_048_576
  @opts [:binary, packet: :line, active: false, buffer: @buffer]

  @doc """
  `$HERDR_LIVE_API`, else `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/api.sock`;
  an empty variable counts as unset. The same rule as `DynideServer.Api.SocketPath`.
  """
  @spec socket_path(%{optional(String.t()) => String.t()}) :: String.t()
  def socket_path(env) do
    case {env(env, "HERDR_LIVE_API"), env(env, "XDG_STATE_HOME")} do
      {nil, nil} -> Path.join(env(env, "HOME") || "", ".local/state/herdr-live/api.sock")
      {nil, state} -> Path.join(state, "herdr-live/api.sock")
      {path, _} -> path
    end
  end

  defp env(env, var), do: if(env[var] in [nil, ""], do: nil, else: env[var])

  @doc "Connects to the socket at `path`, retrying a missing or refused one for `retry_ms`."
  @spec connect(String.t(), non_neg_integer()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(path, retry_ms \\ 2000) do
    attempt(path, now() + retry_ms)
  end

  defp attempt(path, deadline) do
    case :gen_tcp.connect({:local, path}, 0, @opts, @attempt_ms) do
      {:ok, s} ->
        {:ok, s}

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        if now() + @retry_every_ms <= deadline do
          Process.sleep(@retry_every_ms)
          attempt(path, deadline)
        else
          {:error, reason}
        end

      {:error, _} = e ->
        e
    end
  end

  @doc "Sends one request and returns the decoded reply line."
  @spec call(:gen_tcp.socket(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call(sock, method, params, timeout \\ 60_000) do
    line =
      DynideCli.Output.encode(%{"id" => "cli:" <> method, "method" => method, "params" => params})

    with :ok <- :gen_tcp.send(sock, [line, ?\n]),
         {:ok, reply} <- recv_line(sock, deadline(timeout)) do
      decode(reply)
    end
  end

  @doc "The next decoded line of a stream, or `:eof` when the server closed it."
  @spec next(:gen_tcp.socket()) :: {:ok, map()} | :eof | {:error, term()}
  def next(sock) do
    case recv_line(sock, :infinity) do
      {:ok, line} -> decode(line)
      {:error, :closed} -> :eof
      e -> e
    end
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:bad_reply, String.slice(line, 0, 200)}}
    end
  end

  defp recv_line(sock, deadline, acc \\ []) do
    case :gen_tcp.recv(sock, 0, remaining(deadline)) do
      {:ok, data} ->
        if :binary.last(data) == ?\n,
          do: {:ok, IO.iodata_to_binary([acc, data])},
          else: recv_line(sock, deadline, [acc, data])

      {:error, _} = e ->
        e
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: now() + ms

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now(), 0)

  defp now, do: System.monotonic_time(:millisecond)
end
