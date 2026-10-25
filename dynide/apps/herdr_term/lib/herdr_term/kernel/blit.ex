defmodule HerdrTerm.Kernel.Blit do
  @moduledoc """
  Cell blitter contract: `HerdrTerm.Native.Blit.frame/3`. `rows` are
  `{0, row}..{h - 1, row}` in order, `h >= 1`, every row the same non-zero
  column count; anything else (or an unknown shape) is `{:error, :bad_frame}`.

  `opts.graphics` (default `[]`) are kitty graphics ops written in order
  inside the frame, after the cells; a malformed op is `{:error, :bad_frame}`.
  A frame replaced before it was written hands its ops to the replacement.
  `:file` uploads go through a temp file once the host has consumed the
  probe, and direct until then or after the transport failed.
  """

  @type shape ::
          :default | :block_blink | :block | :underline_blink | :underline | :bar_blink | :bar
  @type opts :: %{
          optional(:graphics) => [graphics_op],
          cursor: {non_neg_integer, non_neg_integer} | nil,
          shape: shape,
          repaint: boolean
        }
  @type graphics_op ::
          {:upload,
           %{
             id: pos_integer,
             format: :rgb | :rgba | :png,
             width: pos_integer,
             height: pos_integer,
             data: binary,
             medium: :direct | :file
           }}
          | {:place,
             %{
               id: pos_integer,
               placement: pos_integer,
               x: non_neg_integer,
               y: non_neg_integer,
               cols: pos_integer,
               rows: pos_integer,
               src: {non_neg_integer, non_neg_integer, non_neg_integer, non_neg_integer},
               off: {non_neg_integer, non_neg_integer},
               z: integer
             }}
          | {:delete_placement, pos_integer, pos_integer}
          | {:delete_image, pos_integer}
          | :delete_all
  @callback frame(HerdrTerm.Kernel.Tty.tty(), [{non_neg_integer, binary}], opts) ::
              :ok | {:error, :bad_frame}
end
