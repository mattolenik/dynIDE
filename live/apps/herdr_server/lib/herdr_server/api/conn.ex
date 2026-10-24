defmodule HerdrServer.Api.Conn do
  @moduledoc """
  One API connection: reads JSON lines, answers each in order, until the peer closes.
  Started by `HerdrServer.Api.Listener` per accepted socket (linked to it), which hands
  the socket over with `{:socket, s}`.

  Each request is checked here (JSON, shape, `Api.Spec.fetch/1`,
  `Api.Spec.validate_params/2`) and only then run through `HerdrReload.Guard.run_twice/4`
  into the router, so a crashing handler answers `internal` and the connection lives on.
  A line over 1 MiB answers `invalid_request` (id `""`) and closes the connection.

  Telemetry: `api_denied` for a request refused before or by a handler's capability check
  (`parse_error`, `invalid_request`, `unknown_method`, `invalid_params`, `not_available`),
  `api_error` for a handler that ran and failed (`internal`, `timeout`, `backpressure`,
  `events_lost`). `not_found` and `failed` are normal answers and log nothing.
  """

  alias HerdrReload.{Guard, Telemetry}
  alias HerdrServer.Api.Spec

  @max_line 1_048_576
  @denied ~w(parse_error invalid_request unknown_method invalid_params not_available)a
  @errors ~w(internal timeout backpressure events_lost)a
  @codes Spec.error_codes()

  @doc "The conn process body: waits for the socket, then serves it."
  @spec serve(map()) :: :ok
  def serve(ctx) do
    receive do
      {:socket, s} -> __MODULE__.loop(s, Map.put(ctx, :conn, self()))
    after
      5000 -> :ok
    end
  end

  @doc false
  # A remote call per line and per idle second, so a reload of this module moves an idle
  # connection onto the new code within a second (a soft purge is never blocked).
  @spec loop(:gen_tcp.socket(), map()) :: :ok | {:error, term()}
  def loop(s, ctx) do
    case :gen_tcp.recv(s, 0, 1000) do
      {:ok, line}
      when byte_size(line) >= @max_line and binary_part(line, byte_size(line) - 1, 1) != "\n" ->
        _ = :gen_tcp.send(s, reply("", "", {:error, :invalid_request, "line over 1 MiB"}))
        :gen_tcp.close(s)

      {:ok, line} ->
        {id, method, outcome} = answer(line, ctx)

        case :gen_tcp.send(s, reply(id, method, outcome)) do
          :ok -> __MODULE__.loop(s, ctx)
          {:error, _} -> :gen_tcp.close(s)
        end

      {:error, :timeout} ->
        __MODULE__.loop(s, ctx)

      {:error, _} ->
        :gen_tcp.close(s)
    end
  end

  # {id, method, {:ok, result} | {:error, code, msg} | {:error, code, msg, data}}
  defp answer(line, ctx) do
    case JSON.decode(line) do
      {:ok, req} -> request(req, ctx)
      {:error, _} -> {"", "", {:error, :parse_error, "the line is not valid JSON"}}
    end
  end

  defp request(%{"id" => id, "method" => method} = req, ctx)
       when is_binary(id) and is_binary(method) do
    params = Map.get(req, "params", %{})

    cond do
      not is_map(params) ->
        {id, method, {:error, :invalid_request, "params must be an object"}}

      Spec.fetch(method) == :error ->
        {id, method, {:error, :unknown_method, "unknown method #{method}"}}

      true ->
        case Spec.validate_params(method, params) do
          {:ok, parsed} -> {id, method, run(method, parsed, ctx)}
          {:error, msg} -> {id, method, {:error, :invalid_params, msg}}
        end
    end
  end

  defp request(%{"id" => id}, _ctx) when is_binary(id),
    do: {id, "", {:error, :invalid_request, "method must be a string"}}

  defp request(_req, _ctx),
    do: {"", "", {:error, :invalid_request, "a request is an object with a string id"}}

  defp run(method, params, ctx) do
    args = [method, params, Map.delete(ctx, :router)]

    case Guard.run_twice(ctx.router, :handle, args, server: ctx.reload_server, scan: false) do
      {:ok, {:ok, result}} when is_map(result) ->
        {:ok, result}

      {:ok, {:error, code, msg}} when code in @codes ->
        {:error, code, msg}

      {:ok, {:error, code, msg, data}} when code in @codes and is_map(data) ->
        {:error, code, msg, data}

      {:ok, other} ->
        {:error, :internal, "bad handler reply: #{inspect(other, limit: 5)}"}

      {:failed, failure} ->
        {:error, :internal, Guard.message(failure)}
    end
  end

  defp reply(id, _method, {:ok, result}), do: [JSON.encode!(%{id: id, result: result}), "\n"]

  defp reply(id, method, {:error, code, msg}), do: error(id, method, code, msg, %{})

  defp reply(id, method, {:error, code, msg, data}), do: error(id, method, code, msg, data)

  defp error(id, method, code, msg, data) do
    log(method, code, msg)
    err = %{code: code, message: msg}
    err = if data == %{}, do: err, else: Map.put(err, :data, data)
    [JSON.encode!(%{id: id, error: err}), "\n"]
  end

  defp log(method, code, _msg) when code in @denied,
    do: Telemetry.event(:api_denied, method: String.slice(method, 0, 100), code: code)

  defp log(method, code, msg) when code in @errors,
    do: Telemetry.event(:api_error, method: method, code: code, msg: msg)

  defp log(_method, _code, _msg), do: :ok
end
