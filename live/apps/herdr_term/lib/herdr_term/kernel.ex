defmodule HerdrTerm.Kernel do
  @moduledoc """
  The only way terminal-client code reaches the host terminal: the configured
  `Tty` and `Blit` modules (see `config/config.exs`). Tests run on `Kernel.Fake`.
  """

  @tty Application.compile_env(:herdr_term, [:kernel, :tty], HerdrTerm.Kernel.Fake.Tty)
  @blit Application.compile_env(:herdr_term, [:kernel, :blit], HerdrTerm.Kernel.Fake.Blit)

  @spec tty() :: module
  def tty, do: @tty

  @spec blit() :: module
  def blit, do: @blit
end
