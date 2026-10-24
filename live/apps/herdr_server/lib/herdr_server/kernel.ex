defmodule HerdrServer.Kernel do
  @moduledoc """
  The only way server code reaches the kernel: the configured `Vt`, `Pty` and `Keeper`
  modules (`config :herdr_server, :kernel`; `HerdrServer.Native.*` in dev and prod,
  `Kernel.Fake.*` in test). The config is read once at herdr_server start
  (`HerdrServer.Application`) into one `:persistent_term` key; changing it needs an app
  restart.
  """

  @key __MODULE__

  @doc "Caches the configured kernel modules. Called by `HerdrServer.Application.start/2`."
  @spec load() :: :ok
  def load do
    env =
      case Application.fetch_env(:herdr_server, :kernel) do
        {:ok, env} -> env
        :error -> raise "config :herdr_server, :kernel is not set (see live/config/config.exs)"
      end

    mods = Map.new([:vt, :pty, :keeper], &{&1, fetch!(env, &1)})
    :persistent_term.put(@key, mods)
  end

  defp fetch!(env, key) do
    case Keyword.fetch(env, key) do
      {:ok, mod} -> mod
      :error -> raise "config :herdr_server, :kernel has no #{inspect(key)} module"
    end
  end

  @spec vt() :: module
  def vt, do: :persistent_term.get(@key).vt

  @spec pty() :: module
  def pty, do: :persistent_term.get(@key).pty

  @spec keeper() :: module
  def keeper, do: :persistent_term.get(@key).keeper
end
