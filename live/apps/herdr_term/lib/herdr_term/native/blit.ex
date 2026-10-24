defmodule HerdrTerm.Native.Blit do
  @moduledoc """
  Paints packed rows (`docs/herdr-live/packed-cells.md`) to the host tty.

  The tty's output thread keeps the last frame it wrote and emits only the
  cells that changed. Frames never queue: a frame submitted while the
  previous one is still pending replaces it (counted in
  `HerdrTerm.Native.Tty.stats/1` as dropped, its `repaint` carried over).
  A frame whose rows fail to decode is dropped the same way.
  """

  @behaviour HerdrTerm.Kernel.Blit

  alias HerdrTerm.Native
  alias HerdrTerm.Native.Tty

  @typedoc "Cursor shape, sent as DECSCUSR 0..6."
  @type shape ::
          :default | :block_blink | :block | :underline_blink | :underline | :bar_blink | :bar

  @typedoc """
  `cursor` is the visible cursor cell, or `nil` to hide it. `repaint`
  redraws every cell instead of diffing.
  """
  @type opts :: %{
          cursor: {non_neg_integer(), non_neg_integer()} | nil,
          shape: shape(),
          repaint: boolean()
        }

  @shapes %{
    default: 0,
    block_blink: 1,
    block: 2,
    underline_blink: 3,
    underline: 4,
    bar_blink: 5,
    bar: 6
  }

  @doc """
  Submits a frame without waiting for the host. `rows` must be
  `{0, row}..{h - 1, row}` in order, `h >= 1`, all with the same non-zero
  column count; otherwise (or for an unknown shape) returns
  `{:error, :bad_frame}`.
  """
  @spec frame(Tty.t(), [{non_neg_integer(), binary()}], opts()) ::
          :ok | {:error, :bad_frame}
  def frame(tty, rows, %{cursor: cursor, shape: shape, repaint: repaint}) do
    case Map.fetch(@shapes, shape) do
      {:ok, code} -> Native.blit_frame(tty, rows, cursor, code, repaint)
      :error -> {:error, :bad_frame}
    end
  end
end
