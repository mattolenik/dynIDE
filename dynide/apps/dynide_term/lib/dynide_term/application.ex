defmodule DynideTerm.Application do
  @moduledoc """
  Loads the kernel config (`DynideTerm.Kernel.load/0`), starts
  `DynideTerm.Registry` and, unless headless (`DYNIDE_HEADLESS=1` or
  `config :dynide_term, :headless`), the local terminal client (child id
  `DynideTerm.LocalClient`, registered as `DynideScene.Protocol.local_client_name/0`) once
  the server endpoint exists (`run_local/1`).
  """

  use Application

  require Logger

  alias DynideScene.Protocol

  @impl true
  def start(_type, _args) do
    :ok = DynideTerm.Kernel.load()

    headless? =
      System.get_env("DYNIDE_HEADLESS") == "1" or
        Application.get_env(:dynide_term, :headless, false)

    starter = Supervisor.child_spec({Task, fn -> run_local([]) end}, id: :local_starter)

    children =
      [{Registry, keys: :unique, name: DynideTerm.Registry}] ++
        if(headless?, do: [], else: [starter])

    Supervisor.start_link(children, strategy: :one_for_one, name: DynideTerm.Supervisor)
  end

  @doc false
  # Blocks until the endpoint (`opts[:endpoint]`, default `Protocol.endpoint/0`) exists,
  # then `start_local/1`. A standby VM has no endpoint until it is promoted, so its
  # client never opens /dev/tty under the primary's.
  # ponytail: polls every 20 ms; add a registration notice if the delay matters
  @spec start_when_ready(keyword) :: {:ok, pid} | {:error, term}
  def start_when_ready(opts) do
    if GenServer.whereis(Keyword.get(opts, :endpoint, Protocol.endpoint())) do
      start_local(opts)
    else
      Process.sleep(20)
      start_when_ready(opts)
    end
  end

  @doc false
  # The local starter: starts the client when the endpoint exists. A client stopped by a
  # handoff `:begin` is started again (it repaints) if the handoff is aborted; a client
  # that crashed (any reason but normal/shutdown) is restarted after `restart_delay_ms`
  # (200), at most `max_restarts` (3) per `restart_window_ms` (60 000), then the VM runs
  # headless. A start that fails to open the host tty (`{:tty_open, _}`, no terminal) is
  # not retried: the VM runs headless at once. The starter ends when the client stops
  # otherwise or the handoff completes.
  @spec run_local(keyword) :: :ok
  def run_local(opts), do: run_local(opts, [])

  # restarts: monotonic ms timestamps of the restarts inside the window
  defp run_local(opts, restarts) do
    case start_when_ready(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        reason =
          receive do
            {:DOWN, ^ref, :process, _, reason} -> reason
          end

        cond do
          clear_local_stop() -> if_handoff(opts)
          handoff_phase() == :begin -> await_abort(opts)
          reason == :normal -> :ok
          true -> restart_local(opts, restarts, reason)
        end

      {:error, reason} ->
        case why(reason) do
          # no host terminal (e.g. enxio): environmental, already logged; run headless
          {:tty_open, _} ->
            :ok

          # any other start failure counts as a crash: a rollback may have fixed the code
          _ ->
            restart_local(opts, restarts, reason)
        end
    end

    :ok
  end

  defp if_handoff(opts), do: if(handoff_phase() == :begin, do: await_abort(opts), else: :ok)

  @local_stop {__MODULE__, :local_stop}

  @doc false
  # Marks the next stop of the local client as deliberate (detach, tty hangup, handoff
  # begin): the starter does not restart it.
  @spec mark_local_stop() :: :ok
  def mark_local_stop, do: :persistent_term.put(@local_stop, true)

  defp clear_local_stop do
    marked? = :persistent_term.get(@local_stop, false)
    if marked?, do: :persistent_term.erase(@local_stop)
    marked?
  end

  defp restart_local(opts, restarts, reason) do
    now = System.monotonic_time(:millisecond)
    window = Keyword.get(opts, :restart_window_ms, 60_000)
    recent = Enum.filter(restarts, &(now - &1 < window))

    if length(recent) >= Keyword.get(opts, :max_restarts, 3) do
      Logger.error(
        "terminal client crashed again (#{inspect(reason)}), giving up; running headless"
      )

      DynideReload.Telemetry.event(:crash,
        proc: :local_client,
        action: :gave_up,
        reason: inspect(reason)
      )
    else
      DynideReload.Telemetry.event(:crash,
        proc: :local_client,
        action: :restarted,
        reason: inspect(reason)
      )

      Process.sleep(Keyword.get(opts, :restart_delay_ms, 200))

      if handoff_phase() == :begin, do: await_abort(opts), else: run_local(opts, [now | recent])
    end
  end

  # ponytail: polls every 20 ms like start_when_ready/1
  defp await_abort(opts) do
    case handoff_phase() do
      :begin ->
        Process.sleep(20)
        await_abort(opts)

      :aborted ->
        run_local(opts)

      _released_or_gone ->
        :ok
    end
  end

  defp handoff_phase, do: :persistent_term.get(Protocol.handoff_key(), nil)

  @doc """
  Starts `DynideTerm.LocalClient` under `DynideTerm.Supervisor`, `restart:
  :temporary`: a client that cannot start (no host terminal) or later dies is
  logged once and never restarted; the server keeps running. `opts` go to
  `DynideTerm.Client` (tests pass `tty_opts`).
  """
  @spec start_local(keyword) :: {:ok, pid} | {:error, term}
  def start_local(opts \\ []) do
    spec =
      Supervisor.child_spec(
        {DynideTerm.Client, [name: Protocol.local_client_name(), local: true] ++ opts},
        id: DynideTerm.LocalClient,
        restart: :temporary
      )

    case Supervisor.start_child(DynideTerm.Supervisor, spec) do
      {:ok, pid} ->
        Logger.info("terminal client started")
        {:ok, pid}

      {:error, reason} = err ->
        Logger.error("terminal client not started: #{inspect(why(reason))}")
        err
    end
  end

  # start_child: {reason, child_spec}
  defp why({{:shutdown, {:failed_to_start_child, _, {:shutdown, {:tty_open, reason}}}}, _}),
    do: {:tty_open, reason}

  defp why(reason), do: reason
end
