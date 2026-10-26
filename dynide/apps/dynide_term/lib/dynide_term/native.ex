defmodule DynideTerm.Native do
  @moduledoc """
  Rustler NIF module backed by the `dynide_term` crate. Use the facades
  (`DynideTerm.Native.Tty`, `DynideTerm.Native.Blit`, `DynideTerm.Native.Desktop`) rather than calling these directly.
  """
  use Rustler, otp_app: :dynide_term, crate: :dynide_term, path: "../../native/dynide_term"

  @typedoc "Opaque tty resource."
  @type tty :: reference()

  @typedoc """
  An OS error: the lowercase posix atom (`:enoent`, `:eacces`, `:enxio`,
  `:eio`, `:enotty`, ...) for common errnos, `{:os_error, errno}` for others,
  or a message when the error carries no errno.
  """
  @type posix_error :: :file.posix() | :enotty | {:os_error, integer()} | String.t()

  @doc false
  @spec tty_open(String.t(), non_neg_integer(), reference()) :: :ok | {:error, posix_error()}
  def tty_open(_path, _kitty_flags, _tag), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_restore(tty()) :: :ok
  def tty_restore(_tty), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_suspend(tty()) :: :ok | {:error, :restored | posix_error()}
  def tty_suspend(_tty), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_size(tty()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def tty_size(_tty), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_subscribe(tty(), pid()) :: :ok
  def tty_subscribe(_tty, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_write(tty(), binary()) :: :ok | {:error, :backpressure}
  def tty_write(_tty, _bytes), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_stats(tty()) :: %{
          frames_written: non_neg_integer(),
          frames_dropped: non_neg_integer(),
          queued_bytes: non_neg_integer(),
          graphics_bytes: non_neg_integer(),
          file_transport: :unknown | :probing | :ok | :disabled
        }
  def tty_stats(_tty), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec tty_kitty_keyboard(tty()) :: non_neg_integer() | nil
  def tty_kitty_keyboard(_tty), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec blit_frame(
          tty(),
          [{non_neg_integer(), binary()}],
          {non_neg_integer(), non_neg_integer()} | nil,
          0..6,
          boolean(),
          [DynideTerm.Kernel.Blit.graphics_op()]
        ) :: :ok | {:error, :bad_frame}
  def blit_frame(_tty, _rows, _cursor, _shape, _repaint, _graphics),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec desktop_clipboard_write(binary()) :: :ok | {:error, :unavailable}
  def desktop_clipboard_write(_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec desktop_open_url(binary()) :: :ok | {:error, :unavailable | :bad_url}
  def desktop_open_url(_url), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec desktop_notify(binary(), binary()) :: :ok | {:error, :unavailable}
  def desktop_notify(_title, _body), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec desktop_play(binary()) :: :ok | {:error, :unavailable}
  def desktop_play(_path), do: :erlang.nif_error(:nif_not_loaded)
end
