defmodule DynideTerm.Kernel.Tty do
  @moduledoc """
  Host terminal contract: `DynideTerm.Native.Tty`'s API (see its docs and
  docs/dynide/results/m2.md). The subscriber gets `{:tty_input, binary}`,
  `{:exit, :tty, :hangup | {:panic, binary}}` and, after a `suspend/1` that
  returned `:ok`, `{:tty_resumed}`.
  """

  @type tty :: term
  @type size :: {non_neg_integer, non_neg_integer, non_neg_integer, non_neg_integer}

  @callback open(%{optional(:path) => binary, optional(:kitty_flags) => non_neg_integer}) ::
              {:ok, tty} | {:error, atom | {:panic, binary} | :timeout | term}
  @callback restore(tty) :: :ok
  @callback size(tty) :: size
  @callback subscribe(tty, pid) :: :ok
  @callback write(tty, iodata) :: :ok | {:error, :backpressure}
  @callback stats(tty) :: %{
              frames_written: non_neg_integer,
              frames_dropped: non_neg_integer,
              queued_bytes: non_neg_integer,
              graphics_bytes: non_neg_integer,
              file_transport: :unknown | :probing | :ok | :disabled
            }
  @callback kitty_keyboard(tty) :: non_neg_integer | nil
  @callback suspend(tty) :: :ok | {:error, :restored | atom | term}
end
