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
    env = Application.get_env(:herdr_server, :kernel, [])

    mods = %{
      vt: Keyword.get(env, :vt, HerdrServer.Kernel.Fake.Vt),
      pty: Keyword.get(env, :pty, HerdrServer.Kernel.Fake.Pty),
      keeper: Keyword.get(env, :keeper, HerdrServer.Kernel.Fake.Keeper)
    }

    :persistent_term.put(@key, mods)
  end

  @spec vt() :: module
  def vt, do: :persistent_term.get(@key).vt

  @spec pty() :: module
  def pty, do: :persistent_term.get(@key).pty

  @spec keeper() :: module
  def keeper, do: :persistent_term.get(@key).keeper
end
