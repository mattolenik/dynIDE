defmodule HerdrTerm.Native.Tty do
  @moduledoc """
  The host terminal: raw mode, alternate screen, kitty keyboard probe, input,
  and restore. The tty is restored when `restore/1` is called or when the
  resource is garbage collected, whichever comes first.

  Subscriber messages:

    * `{:tty_input, binary}`
    * `{:exit, :tty, :hangup}` on EOF/EIO
    * `{:exit, :tty, {:panic, binary}}`
    * `{:tty_resumed}` after `suspend/1` returns `:ok`; send a frame, it
      repaints fully. The restore sequence written before the stop turned off
      mouse reporting, bracketed paste and focus events: re-send any of those
      modes the client had enabled (kitty flags are re-pushed for you)

  Probe replies that arrive after the 250 ms deadline are delivered as
  ordinary `{:tty_input, binary}`.
  """

  @behaviour HerdrTerm.Kernel.Tty

  alias HerdrTerm.Native

  @type t :: Native.tty()

  # The kernel thread replies within the 250 ms probe plus write budgets.
  @open_timeout 5_000

  @doc """
  Opens the tty. Options: `:path` (default `"/dev/tty"`), `:kitty_flags`
  (default `0`, pushed only when the probe confirmed kitty keyboard support).
  Errors are `t:HerdrTerm.Native.posix_error/0` (`{:error, :enoent}`,
  `{:error, :enxio}`, ...), `{:error, {:panic, binary}}`, or
  `{:error, :timeout}` when the kernel thread did not reply in 5 s.
  """
  @spec open(map()) ::
          {:ok, t()} | {:error, Native.posix_error() | {:panic, String.t()} | :timeout}
  def open(opts \\ %{}) do
    path = Map.get(opts, :path, "/dev/tty")
    flags = Map.get(opts, :kitty_flags, 0)
    tag = make_ref()

    with :ok <- Native.tty_open(path, flags, tag) do
      receive do
        {^tag, result} -> result
      after
        @open_timeout ->
          # A reply that raced the timeout must not leave a raw tty behind.
          # ponytail: one that lands after this flush still lingers until the
          # caller exits; the open work is bounded well under the timeout.
          receive do
            {^tag, {:ok, tty}} -> restore(tty)
            {^tag, _} -> :ok
          after
            0 -> :ok
          end

          {:error, :timeout}
      end
    end
  end

  @doc "Restores the host terminal. Idempotent."
  @spec restore(t()) :: :ok
  def restore(tty), do: Native.tty_restore(tty)

  @doc """
  Restores the host terminal, stops the whole OS process (SIGSTOP to the
  process group, like a shell job) and returns once it is continued, back in
  raw mode and the alternate screen with any kitty flags re-pushed. Blocks
  the caller until SIGCONT; queued output waits and is written after resume.

  Returns `:ok` exactly when `{:tty_resumed}` follows. Returns
  `{:error, :restored}` (nothing done) after `restore/1`, and
  `{:error, posix_error}` when the terminal could not be reset or the
  event thread could not start, in which case the process was not stopped
  and no `{:tty_resumed}` is sent.
  """
  @spec suspend(t()) :: :ok | {:error, :restored | Native.posix_error()}
  def suspend(tty), do: Native.tty_suspend(tty)

  @doc """
  `{cols, rows, pixel_width, pixel_height}` of the host terminal. Raises
  `ErlangError` with the `t:HerdrTerm.Native.posix_error/0` (e.g. `:enotty`)
  when the size cannot be read (the fd is not, or no longer, a terminal).
  """
  @spec size(t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def size(tty), do: Native.tty_size(tty)

  @doc "Sends input and exit events to `pid`, starting with input buffered so far."
  @spec subscribe(t(), pid()) :: :ok
  def subscribe(tty, pid), do: Native.tty_subscribe(tty, pid)

  @doc """
  Queues bytes for the host terminal without waiting for it. Returns
  `{:error, :backpressure}` (nothing queued) when the 1 MiB write queue cannot
  take them; a single write over 1 MiB is always refused. After `restore/1`
  writes are discarded and return `:ok`.
  """
  @spec write(t(), iodata()) :: :ok | {:error, :backpressure}
  def write(tty, iodata), do: Native.tty_write(tty, IO.iodata_to_binary(iodata))

  @doc "Output counters: frames written and dropped, raw bytes still queued."
  @spec stats(t()) :: %{
          frames_written: non_neg_integer(),
          frames_dropped: non_neg_integer(),
          queued_bytes: non_neg_integer()
        }
  def stats(tty), do: Native.tty_stats(tty)

  @doc "Kitty keyboard flags reported by the host, or `nil` without support."
  @spec kitty_keyboard(t()) :: non_neg_integer() | nil
  def kitty_keyboard(tty), do: Native.tty_kitty_keyboard(tty)
end
