defmodule HerdrServer.Kernel do
  @moduledoc """
  The only way server code reaches the kernel: the configured `Vt`, `Pty` and
  `Keeper` modules (see `config/config.exs`). Tests run on `Kernel.Fake`.
  """

  @vt Application.compile_env(:herdr_server, [:kernel, :vt], HerdrServer.Kernel.Fake.Vt)
  @pty Application.compile_env(:herdr_server, [:kernel, :pty], HerdrServer.Kernel.Fake.Pty)
  @keeper Application.compile_env(
            :herdr_server,
            [:kernel, :keeper],
            HerdrServer.Kernel.Fake.Keeper
          )

  @spec vt() :: module
  def vt, do: @vt

  @spec pty() :: module
  def pty, do: @pty

  @spec keeper() :: module
  def keeper, do: @keeper
end
