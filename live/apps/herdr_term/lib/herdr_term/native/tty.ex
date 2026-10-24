defmodule HerdrTerm.Native.Tty do
  @moduledoc """
  The host terminal: raw mode, alternate screen, kitty keyboard probe, input,
  and restore. The tty is restored when `restore/1` is called or when the
  resource is garbage collected, whichever comes first.

  Subscriber messages:

    * `{:tty_input, binary}`
    * `{:exit, :tty, :hangup}` on EOF/EIO
    * `{:exit, :tty, {:panic, binary}}`

  Probe replies that arrive after the 250 ms deadline are delivered as
  ordinary `{:tty_input, binary}`.
  """

  alias HerdrTerm.Native

  @type t :: Native.tty()

  # The kernel thread replies within the 250 ms probe plus write budgets.
  @open_timeout 5_000

  @doc """
  Opens the tty. Options: `:path` (default `"/dev/tty"`), `:kitty_flags`
  (default `0`, pushed only when the probe confirmed kitty keyboard support).
  """
  @spec open(map()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ %{}) do
    path = Map.get(opts, :path, "/dev/tty")
    flags = Map.get(opts, :kitty_flags, 0)
    tag = make_ref()

    with :ok <- Native.tty_open(path, flags, tag) do
      receive do
        {^tag, result} -> result
      after
        @open_timeout -> {:error, :timeout}
      end
    end
  end

  @doc "Restores the host terminal. Idempotent."
  @spec restore(t()) :: :ok
  def restore(tty), do: Native.tty_restore(tty)

  @doc "`{cols, rows, pixel_width, pixel_height}` of the host terminal."
  @spec size(t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def size(tty), do: Native.tty_size(tty)

  @doc "Sends input and exit events to `pid`, starting with input buffered so far."
  @spec subscribe(t(), pid()) :: :ok
  def subscribe(tty, pid), do: Native.tty_subscribe(tty, pid)

  @doc "Kitty keyboard flags reported by the host, or `nil` without support."
  @spec kitty_keyboard(t()) :: non_neg_integer() | nil
  def kitty_keyboard(tty), do: Native.tty_kitty_keyboard(tty)
end
