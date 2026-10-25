defmodule HerdrTerm.Remote do
  @moduledoc """
  The remote terminal client: `herdr-live attach|terminal ...` runs `main/1` in a VM of
  its own (R18). `HerdrTerm.Remote.Conn` is the endpoint; the `HerdrTerm.Client`
  (child id `HerdrTerm.RemoteClient`) attaches to it with inline rows and `remote: true`
  (a hangup or detach ends the VM).

  Exit status: 0 for a detach or a hangup, 1 after `fail/1` (a refusal, an unreachable
  host), whose reason is written to `$HERDR_LIVE_CLIENT_REASON` for `bin/herdr-live` to
  print (the VM's own stdio goes to the client log), 2 for usage.
  """

  alias HerdrTerm.Client
  alias HerdrTerm.Remote.{Args, Conn}

  @apps [:herdr_scene, :herdr_reload, :herdr_term]

  @spec main([binary]) :: no_return
  def main(argv) do
    case Args.parse(argv, System.get_env()) do
      {:usage, text} ->
        IO.puts(:stderr, text)
        _ = fail(text)
        System.halt(2)

      {:ok, opts} ->
        Application.put_env(:herdr_term, :on_local_exit, {__MODULE__, :stop, []})
        # R7: `[:safe]` decoding knows only the atoms of loaded modules
        preload()
        reload = Application.get_env(:herdr_reload, HerdrReload, [])
        Application.put_env(:herdr_reload, HerdrReload, Keyword.put(reload, :enabled, false))
        Application.put_env(:herdr_term, :headless, true)
        {:ok, _} = Application.ensure_all_started(:herdr_term, :permanent)

        case start(opts) do
          {:ok, _} ->
            Process.sleep(:infinity)

          {:error, why} ->
            _ = fail("cannot start the terminal client: #{start_error(why)}")
            System.halt(1)
        end
    end
  end

  @doc "Marks the VM failed (status 1) and writes `reason` to `$HERDR_LIVE_CLIENT_REASON`."
  @spec fail(binary) :: :ok
  def fail(reason) do
    :persistent_term.put({__MODULE__, :status}, 1)

    case System.get_env("HERDR_LIVE_CLIENT_REASON") do
      p when p in [nil, ""] -> :ok
      path -> _ = File.write(path, reason)
    end

    :ok
  end

  @doc false
  # the client's on_local_exit in this VM
  @spec stop() :: :ok
  def stop, do: System.stop(:persistent_term.get({__MODULE__, :status}, 0))

  # the usual one: no controlling terminal
  defp start_error({{:shutdown, {:failed_to_start_child, _, {:shutdown, {:tty_open, e}}}}, _}),
    do: "cannot open /dev/tty (#{e})"

  defp start_error(why), do: inspect(why, limit: 8)

  @doc "Loads every module of the client's apps (R7)."
  @spec preload() :: :ok
  def preload do
    for app <- @apps do
      _ = Application.load(app)
      {:ok, mods} = :application.get_key(app, :modules)
      Enum.each(mods, &Code.ensure_loaded!/1)
    end

    :ok
  end

  @doc "Starts `Conn` (`opts`) and the remote client under `HerdrTerm.Supervisor`."
  @spec start(keyword) :: {:ok, pid} | {:error, term}
  def start(opts) do
    client = [endpoint: Keyword.get(opts, :name, Conn), transport: :inline, remote: true]

    with {:ok, _} <- Supervisor.start_child(HerdrTerm.Supervisor, {Conn, opts}) do
      Supervisor.start_child(
        HerdrTerm.Supervisor,
        Supervisor.child_spec({Client, client}, id: HerdrTerm.RemoteClient)
      )
    end
  end
end
