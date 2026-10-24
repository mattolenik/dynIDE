defmodule HerdrTerm.Kernel.Blit do
  @moduledoc """
  Cell blitter contract: `HerdrTerm.Native.Blit.frame/3`. `rows` are
  `{0, row}..{h - 1, row}` in order, `h >= 1`, every row the same non-zero
  column count; anything else (or an unknown shape) is `{:error, :bad_frame}`.
  """

  @type shape ::
          :default | :block_blink | :block | :underline_blink | :underline | :bar_blink | :bar
  @type opts :: %{
          cursor: {non_neg_integer, non_neg_integer} | nil,
          shape: shape,
          repaint: boolean
        }
  @callback frame(HerdrTerm.Kernel.Tty.tty(), [{non_neg_integer, binary}], opts) ::
              :ok | {:error, :bad_frame}
end
