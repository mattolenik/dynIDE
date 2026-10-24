defmodule HerdrCli do
  @moduledoc """
  `herdr-live <verb>`: parse argv (`HerdrCli.Argv`), send one request over the API
  socket (`HerdrCli.Client`), print the reply (`HerdrCli.Output`).

  Exit codes: 0 success, 1 an API error (the `error` object as JSON on stderr) or
  `herdr-live is not running`, 2 a usage error.

  `bin/herdr-live` starts this as `erl -noinput -run Elixir.HerdrCli main_erl -extra
  <args>` (no Elixir boot, no stdin reads, so it is safe in `while read` loops).
  """

  alias HerdrCli.{Argv, Client, Output}

  @doc "Entry for `erl -run`: argv comes from the plain arguments after `-extra`."
  @spec main_erl() :: no_return()
  def main_erl do
    main(Enum.map(:init.get_plain_arguments(), &chars/1))
  end

  @doc false
  # erts hands argv and env over as code points under a utf8 native name encoding and
  # as raw bytes under latin1; the encoding decides, never the content.
  @spec chars(charlist(), :utf8 | :latin1) :: String.t()
  def chars(list, encoding \\ :file.native_name_encoding())
  def chars(list, :utf8), do: List.to_string(list)
  def chars(list, :latin1), do: :erlang.list_to_binary(list)

  defp env, do: Map.new(:os.env(), fn {k, v} -> {chars(k), chars(v)} end)

  @doc "Runs argv and halts the VM with the exit code."
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    # Output is UTF-8 bytes written raw; a unicode-mode device would encode them again.
    :ok = :io.setopts(:standard_io, encoding: :latin1)
    :ok = :io.setopts(:standard_error, encoding: :latin1)
    # Crash reports go to stderr: stdout carries only the reply (callers parse it).
    _ = :logger.remove_handler(:default)
    _ = :logger.add_handler(:default, :logger_std_h, %{config: %{type: :standard_error}})

    # In its own process so a crash prints one line and exits 1, without a
    # blanket rescue here or an init crash dump.
    {_pid, ref} = spawn_monitor(fn -> exit({:shutdown, run(argv, env())}) end)

    code =
      receive do
        {:DOWN, ^ref, :process, _, {:shutdown, code}} when is_integer(code) ->
          code

        {:DOWN, ^ref, :process, _, reason} ->
          err("herdr-live: internal error: #{inspect(reason, limit: 20)}\n")
          1
      end

    :erlang.halt(code)
  end

  @doc "Runs argv against `env`, writing to stdout/stderr; returns the exit code."
  @spec run([String.t()], %{optional(String.t()) => String.t()}) :: 0 | 1 | 2
  def run(argv, env) do
    case Argv.parse(argv, env) do
      {:usage, text} ->
        err(text)
        2

      {:call, method, params, out} ->
        with_socket(env, fn s -> call(s, method, params, out) end)

      {:subscribe, params} ->
        with_socket(env, fn s -> subscribe(s, params) end)
    end
  end

  defp with_socket(env, fun) do
    path = Client.socket_path(env)

    case Client.connect(path) do
      {:ok, s} ->
        fun.(s)

      {:error, r} when r in [:enoent, :econnrefused] ->
        err("herdr-live is not running\n")
        1

      {:error, r} ->
        err("herdr-live: cannot connect to #{path}: #{inspect(r)}\n")
        1
    end
  end

  defp call(s, method, params, out) do
    case Client.call(s, method, params, timeout(method, params)) do
      {:ok, reply} -> emit(Output.render(out, reply))
      {:error, r} -> lost(r)
    end
  end

  # Waits are bounded by the server (timeout_ms); allow a margin for the reply.
  defp timeout(method, params) when method in ["pane.wait_for_output", "agent.wait"] do
    case params do
      %{"timeout_ms" => ms} when is_integer(ms) and ms > 0 -> ms + 10_000
      _ -> :infinity
    end
  end

  defp timeout(_method, _params), do: 60_000

  defp subscribe(s, params) do
    case Client.call(s, "events.subscribe", params) do
      {:ok, %{"result" => _}} -> stream(s)
      {:ok, reply} -> emit(Output.render(:json, reply))
      {:error, r} -> lost(r)
    end
  end

  defp stream(s) do
    case Client.next(s) do
      {:ok, %{"error" => _} = reply} -> emit(Output.render(:json, reply))
      # a reader that went away (`| head`) ends the stream
      {:ok, event} -> if out(Output.event(event)) == :ok, do: stream(s), else: 0
      :eof -> 0
      {:error, r} -> lost(r)
    end
  end

  defp lost(r) do
    err(["herdr-live: ", lost_msg(r), ?\n])
    1
  end

  defp lost_msg(:closed), do: "connection closed before a reply"
  defp lost_msg(:timeout), do: "no reply in time"
  defp lost_msg(r), do: inspect(r, limit: 20)

  defp emit({0, text}) do
    out(text)
    0
  end

  defp emit({code, {:stderr, text}}) do
    err(text)
    code
  end

  # Raw bytes (main/1 puts both devices in latin1 mode, so nothing is re-encoded).
  defp out(text), do: :file.write(:standard_io, text)
  defp err(text), do: :file.write(:standard_error, text)
end
