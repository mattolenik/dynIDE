defmodule HerdrServer.Test.ApiClient do
  @moduledoc "Test helper: a line-JSON client for `HerdrServer.Api.Listener`."

  @opts [:binary, packet: :line, buffer: 1_048_576, active: false]

  @spec connect(Path.t()) :: :gen_tcp.socket()
  def connect(path) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, @opts, 5000)
    s
  end

  @doc "Sends one request and returns the decoded response."
  @spec call(:gen_tcp.socket(), String.t(), map() | nil, String.t()) :: map()
  def call(sock, method, params \\ nil, id \\ "t") do
    req = %{"id" => id, "method" => method}
    req = if params, do: Map.put(req, "params", params), else: req
    :ok = send_line(sock, JSON.encode!(req))
    recv_line(sock)
  end

  @doc "Connects, sends one request, closes."
  @spec once(Path.t(), String.t(), map() | nil) :: map()
  def once(path, method, params \\ nil) do
    s = connect(path)
    reply = call(s, method, params)
    :gen_tcp.close(s)
    reply
  end

  @spec send_line(:gen_tcp.socket(), iodata()) :: :ok | {:error, term()}
  def send_line(sock, line), do: :gen_tcp.send(sock, [line, "\n"])

  @doc "The next response line, decoded; `{:error, reason}` when none arrives."
  @spec recv_line(:gen_tcp.socket(), timeout()) :: map() | {:error, term()}
  def recv_line(sock, timeout \\ 10_000) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, line} -> JSON.decode!(line)
      {:error, _} = e -> e
    end
  end
end
