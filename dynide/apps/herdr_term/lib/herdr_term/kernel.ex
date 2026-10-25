defmodule HerdrTerm.Kernel do
  @moduledoc """
  The only way terminal-client code reaches the host terminal: the configured
  `Tty`, `Blit` and `Desktop` modules (`config :herdr_term, :kernel`; `HerdrTerm.Native.*`
  in dev and prod, `Kernel.Fake.*` in test). `sigwinch` says whether the tty
  kernel is a real terminal whose size changes arrive as SIGWINCH (`Tty.Owner`
  then installs the signal handler). The config is read once at herdr_term
  start (`HerdrTerm.Application`) into one `:persistent_term` key; changing it
  needs an app restart.
  """

  @key __MODULE__

  @doc "Caches the configured kernel modules. Called by `HerdrTerm.Application.start/2`."
  @spec load() :: :ok
  def load do
    env =
      case Application.fetch_env(:herdr_term, :kernel) do
        {:ok, env} -> env
        :error -> raise "config :herdr_term, :kernel is not set (see dynide/config/config.exs)"
      end

    :persistent_term.put(
      @key,
      Map.new([:tty, :blit, :desktop, :sigwinch], &{&1, fetch!(env, &1)})
    )
  end

  defp fetch!(env, key) do
    case Keyword.fetch(env, key) do
      {:ok, val} -> val
      :error -> raise "config :herdr_term, :kernel has no #{inspect(key)} entry"
    end
  end

  @spec tty() :: module
  def tty, do: :persistent_term.get(@key).tty

  @spec blit() :: module
  def blit, do: :persistent_term.get(@key).blit

  @spec desktop() :: module
  # an older cached map (loaded before `desktop` existed) has no entry
  def desktop, do: Map.get(:persistent_term.get(@key), :desktop, HerdrTerm.Native.Desktop)

  @spec sigwinch?() :: boolean
  def sigwinch?, do: :persistent_term.get(@key).sigwinch
end
