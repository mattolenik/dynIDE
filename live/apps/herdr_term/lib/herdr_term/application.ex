defmodule HerdrTerm.Application do
  @moduledoc """
  Loads the kernel config (`HerdrTerm.Kernel.load/0`), starts
  `HerdrTerm.Registry` and, unless headless (`HERDR_LIVE_HEADLESS=1` or
  `config :herdr_term, :headless`), the local terminal client `HerdrTerm.LocalClient`.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = HerdrTerm.Kernel.load()

    headless? =
      System.get_env("HERDR_LIVE_HEADLESS") == "1" or
        Application.get_env(:herdr_term, :headless, false)

    children = [{Registry, keys: :unique, name: HerdrTerm.Registry}]

    with {:ok, _} = ok <-
           Supervisor.start_link(children, strategy: :one_for_one, name: HerdrTerm.Supervisor) do
      if not headless?, do: start_local()
      ok
    end
  end

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
        {HerdrTerm.Client, [name: HerdrTerm.LocalClient, local: true] ++ opts},
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
