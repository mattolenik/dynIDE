defmodule HerdrTerm.Remote do
  @moduledoc """
  The remote terminal client: `herdr-live attach|terminal ...` runs `main/1` in a VM of
  its own (R18). `HerdrTerm.Remote.Conn` is the endpoint; the `HerdrTerm.Client`
  (child id `HerdrTerm.RemoteClient`) attaches to it with inline rows and `remote: true`
  (a hangup or detach ends the VM).
  """

  alias HerdrTerm.Client
  alias HerdrTerm.Remote.{Args, Conn}

  @apps [:herdr_scene, :herdr_reload, :herdr_term]

  @spec main([binary]) :: no_return
  def main(argv) do
    case Args.parse(argv, System.get_env()) do
      {:usage, text} ->
        IO.puts(:stderr, text)
        System.halt(2)

      {:ok, opts} ->
        # R7: `[:safe]` decoding knows only the atoms of loaded modules
        preload()
        reload = Application.get_env(:herdr_reload, HerdrReload, [])
        Application.put_env(:herdr_reload, HerdrReload, Keyword.put(reload, :enabled, false))
        Application.put_env(:herdr_term, :headless, true)
        {:ok, _} = Application.ensure_all_started(:herdr_term, :permanent)
        {:ok, _} = start(opts)
        Process.sleep(:infinity)
    end
  end

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
