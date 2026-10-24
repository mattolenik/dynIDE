defmodule HerdrTerm.Application do
  @moduledoc """
  Loads the kernel config (`HerdrTerm.Kernel.load/0`), starts
  `HerdrTerm.Registry` and, unless headless (`HERDR_LIVE_HEADLESS=1` or
  `config :herdr_term, :headless`), the local terminal client (child id
  `HerdrTerm.LocalClient`, registered as `HerdrScene.Protocol.local_client_name/0`) once
  the server endpoint exists (`run_local/1`).
  """

  use Application

  require Logger

  alias HerdrScene.Protocol

  @impl true
  def start(_type, _args) do
    :ok = HerdrTerm.Kernel.load()

    headless? =
      System.get_env("HERDR_LIVE_HEADLESS") == "1" or
        Application.get_env(:herdr_term, :headless, false)

    starter = Supervisor.child_spec({Task, fn -> run_local([]) end}, id: :local_starter)

    children =
      [{Registry, keys: :unique, name: HerdrTerm.Registry}] ++
        if(headless?, do: [], else: [starter])

    Supervisor.start_link(children, strategy: :one_for_one, name: HerdrTerm.Supervisor)
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
  # handoff `:begin` is started again (it repaints) if the handoff is aborted; the
  # starter ends when the client stops for any other reason or the handoff completes.
  @spec run_local(keyword) :: :ok
  def run_local(opts) do
    with {:ok, pid} <- start_when_ready(opts) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end

      if handoff_phase() == :begin, do: await_abort(opts)
    end

    :ok
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
  Starts `HerdrTerm.LocalClient` under `HerdrTerm.Supervisor`, `restart:
  :temporary`: a client that cannot start (no host terminal) or later dies is
  logged once and never restarted; the server keeps running. `opts` go to
  `HerdrTerm.Client` (tests pass `tty_opts`).
  """
  @spec start_local(keyword) :: {:ok, pid} | {:error, term}
  def start_local(opts \\ []) do
    spec =
      Supervisor.child_spec(
        {HerdrTerm.Client, [name: Protocol.local_client_name(), local: true] ++ opts},
        id: HerdrTerm.LocalClient,
        restart: :temporary
      )

    case Supervisor.start_child(HerdrTerm.Supervisor, spec) do
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
