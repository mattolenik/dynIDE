defmodule HerdrTerm.Kernel.Tty do
  @moduledoc "Host terminal contract (design.md `Native.Tty`)."

  @type tty :: term
  @callback open() :: {:ok, tty}
  @callback restore(tty) :: :ok
  @callback size(tty) :: {pos_integer, pos_integer, non_neg_integer, non_neg_integer}
  @callback subscribe(tty, pid) :: :ok
  @callback write(tty, iodata) :: :ok
  @callback suspend(tty) :: :ok
end
