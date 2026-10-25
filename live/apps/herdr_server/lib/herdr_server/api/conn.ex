defmodule HerdrServer.Api.Conn do
  @moduledoc """
  One API connection: reads JSON lines, answers each in order, until the peer closes.
  Started by `HerdrServer.Api.Listener` per accepted socket (linked to it), which hands
  the socket over with `{:socket, s}`. The socket is `{active, once}`, re-armed before
  each handler runs; `ctx` carries `conn` (this pid) and `socket`. A handler that must
  wait answers `{:continue, {m, f, a}}` and is polled from here (`continue/5`), so a
  long wait holds no handler frames and still sees a peer close.

  `events.subscribe` (the router answers `{:subscribe, filters}` once `Api.Events` holds
  them) turns the connection into an event stream: `subscription_started`, then one
  `{"event": type, "data": {...}}` line per `{:api_event, event}`. Request lines on it are
  ignored. A refused subscription answers its error and closes.

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
  alias HerdrServer.Api.{Events, Spec}

  @max_line 1_048_576
  @poll_ms 100
  @max_pending 16
  @drain_ms 1000
  @drain_bytes 8_388_608
  @max_queue 1000
  @send_timeout_ms 5000
  @denied ~w(parse_error invalid_request unknown_method invalid_params not_available)a
  @errors ~w(internal timeout backpressure events_lost)a
  @codes Spec.error_codes()

  @doc "The conn process body: waits for the socket, then serves it."
  @spec serve(map()) :: :ok
  def serve(ctx) do
    receive do
      {:socket, s} ->
        case :inet.setopts(s, active: :once) do
          :ok -> __MODULE__.loop(s, ctx |> Map.put(:conn, self()) |> Map.put(:socket, s))
          {:error, _} -> :gen_tcp.close(s)
        end
    after
      5000 -> :ok
    end
  end

  @doc false
  # A remote call per line and per idle second, so a reload of this module moves an idle
  # connection onto the new code within a second (a soft purge is never blocked).
  # Lines that arrived during a wait (`ctx.pending`) are answered first, in order.
  @spec loop(:gen_tcp.socket(), map()) :: :ok
  def loop(s, %{pending: [line | rest]} = ctx), do: line(s, line, %{ctx | pending: rest})

  def loop(s, ctx) do
    receive do
      {:tcp, ^s, line} -> line(s, line, ctx)
      {:tcp_closed, ^s} -> :gen_tcp.close(s)
      {:tcp_error, ^s, _} -> :gen_tcp.close(s)
    after
      1000 -> __MODULE__.loop(s, ctx)
    end
  end

  @doc false
  # A handler's `{:continue, {m, f, a}}` (a `pane.wait_for_output` that has not matched
  # yet): `m.f(a...)` runs again through the guard every #{@poll_ms} ms until it answers.
  # Each poll is a remote call, so a wait pins no old code of this module or the
  # handler's. A peer close ends the wait without an answer; a pipelined request line
  # is kept in `ctx.pending` (up to #{@max_pending}) and the socket re-armed, so a close
  # behind it is still seen.
  @spec continue(:gen_tcp.socket(), String.t(), String.t(), {module(), atom(), list()}, map()) ::
          :ok
  def continue(s, id, method, {m, f, a} = mfa, ctx) do
    receive do
      {:tcp, ^s, line} ->
        ctx = Map.update(ctx, :pending, [line], &(&1 ++ [line]))
        if length(ctx.pending) < @max_pending, do: _ = :inet.setopts(s, active: :once)
        __MODULE__.continue(s, id, method, mfa, ctx)

      {:tcp_closed, ^s} ->
        :gen_tcp.close(s)

      {:tcp_error, ^s, _} ->
        :gen_tcp.close(s)
    after
      @poll_ms -> answered(s, id, method, outcome(method, guarded(m, f, a, ctx)), ctx)
    end
  end

  defp line(s, line, _ctx)
       when byte_size(line) >= @max_line and binary_part(line, byte_size(line) - 1, 1) != "\n" do
    _ = :gen_tcp.send(s, reply("", "", {:error, :invalid_request, "line over 1 MiB"}))
    # Closing with the rest of the line unread resets the peer on Linux and the reply is
    # lost: end our side, then read and discard until the peer closes (bounded).
    _ = :gen_tcp.shutdown(s, :write)
    _ = :inet.setopts(s, active: false, packet: :raw)
    __MODULE__.drain(s, System.monotonic_time(:millisecond) + @drain_ms, @drain_bytes)
  end

  defp line(s, line, ctx) do
    # re-armed before the handler runs, so a close during a long handler is a message
    _ = :inet.setopts(s, active: :once)
    {id, method, outcome} = answer(line, ctx)
    answered(s, id, method, outcome, ctx)
  end

  @doc false
  # Discards input until the peer closes, #{@drain_ms} ms pass or #{@drain_bytes} bytes
  # were read, then closes. A remote call per read, like `loop/2`.
  @spec drain(:gen_tcp.socket(), integer(), integer()) :: :ok
  def drain(s, deadline, left) do
    wait = deadline - System.monotonic_time(:millisecond)

    with true <- wait > 0 and left > 0,
         {:ok, data} <- :gen_tcp.recv(s, 0, wait) do
      __MODULE__.drain(s, deadline, left - byte_size(data))
    else
      _ -> :gen_tcp.close(s)
    end
  end

  defp answered(s, id, _method, {:subscribe, filters}, ctx), do: start_stream(s, id, filters, ctx)

  defp answered(s, id, method, {:continue, mfa}, ctx),
    do: __MODULE__.continue(s, id, method, mfa, ctx)

  defp answered(s, id, method, outcome, ctx) do
    sent = :gen_tcp.send(s, reply(id, method, outcome))

    # a refused subscription closes, like herdr's
    if sent == :ok and not (method == "events.subscribe" and elem(outcome, 0) == :error),
      do: __MODULE__.loop(s, ctx),
      else: :gen_tcp.close(s)
  end

  # --- subscription mode ---

  defp start_stream(s, id, filters, ctx) do
    result = %{type: "subscription_started", subscriptions: length(filters)}
    _ = :inet.setopts(s, send_timeout: @send_timeout_ms, send_timeout_close: true)
    # the hub going away loses this subscription: events_lost (a DOWN at once if gone)
    hub = Process.monitor(Events)

    case :gen_tcp.send(s, reply(id, "events.subscribe", {:ok, result})) do
      :ok -> __MODULE__.stream(s, ctx |> Map.put(:sub_id, id) |> Map.put(:hub, hub))
      {:error, _} -> :gen_tcp.close(s)
    end
  end

  @doc false
  # Writes each `{:api_event, event}` as one line; ignores request lines. More than
  # #{@max_queue} queued messages, a write blocked #{@send_timeout_ms} ms, or the
  # `Api.Events` hub exiting is `events_lost` and closes. A remote call per event and
  # idle second, like `loop/2`.
  @spec stream(:gen_tcp.socket(), map()) :: :ok
  def stream(s, %{hub: hub} = ctx) do
    receive do
      {:api_event, event} -> event(s, event, ctx)
      {:DOWN, ^hub, :process, _, _} -> lost(s, ctx, "the event hub stopped")
      {:tcp, ^s, _line} -> rearm(s, ctx)
      {:tcp_closed, ^s} -> :gen_tcp.close(s)
      {:tcp_error, ^s, _} -> :gen_tcp.close(s)
    after
      1000 -> __MODULE__.stream(s, ctx)
    end
  end

  defp lost(s, ctx, msg) do
    _ = :gen_tcp.send(s, reply(ctx.sub_id, "events.subscribe", {:error, :events_lost, msg}))
    :gen_tcp.close(s)
  end

  defp rearm(s, ctx) do
    case :inet.setopts(s, active: :once) do
      :ok -> __MODULE__.stream(s, ctx)
      {:error, _} -> :gen_tcp.close(s)
    end
  end

  defp event(s, event, ctx) do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

    if queued > @max_queue do
      lost(s, ctx, "subscriber fell #{queued} messages behind")
    else
      {type, data} = Map.pop(event, "event")

      case :gen_tcp.send(s, [JSON.encode!(%{event: type, data: data}), "\n"]) do
        :ok ->
          __MODULE__.stream(s, ctx)

        {:error, :timeout} ->
          log("events.subscribe", :events_lost, "subscriber stopped reading")
          :gen_tcp.close(s)

        {:error, _} ->
          :gen_tcp.close(s)
      end
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

  defp run(method, params, ctx),
    do: outcome(method, guarded(ctx.router, :handle, [method, params], ctx))

  # the handler's ctx: without the router and the lines kept for later
  defp guarded(m, f, a, ctx) do
    ctx = Map.drop(ctx, [:router, :pending])
    Guard.run_twice(m, f, a ++ [ctx], server: ctx.reload_server, scan: false)
  end

  defp outcome(method, {:ok, reply}), do: handler_reply(method, reply)
  defp outcome(_method, {:failed, failure}), do: {:error, :internal, Guard.message(failure)}

  defp handler_reply(_method, {:ok, result}) when is_map(result), do: {:ok, result}

  defp handler_reply("events.subscribe", {:subscribe, filters}) when is_list(filters),
    do: {:subscribe, filters}

  defp handler_reply(_method, {:continue, {m, f, a}})
       when is_atom(m) and is_atom(f) and is_list(a),
       do: {:continue, {m, f, a}}

  defp handler_reply(_method, {:error, code, msg}) when code in @codes, do: {:error, code, msg}

  defp handler_reply(_method, {:error, code, msg, data}) when code in @codes and is_map(data),
    do: {:error, code, msg, data}

  defp handler_reply(_method, other),
    do: {:error, :internal, "bad handler reply: #{inspect(other, limit: 5)}"}

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
