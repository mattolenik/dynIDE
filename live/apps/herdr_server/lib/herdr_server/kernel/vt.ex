defmodule HerdrServer.Kernel.Vt do
  @moduledoc """
  Terminal state kernel: the API of `HerdrServer.Native.Vt` (M1), which implements it.
  `Kernel.Fake.Vt` is the test double. Shapes are M1's (docs/herdr-live/results/m1.md).

  `dirty_rows/1` has ONE shared read cursor per vt: `Pane.Server` is its only consumer
  (sessions read the `Pane.Rows` cache). Never call it anywhere else.
  """

  @type vt :: term
  @type row :: HerdrScene.Cell.row()
  @type rows :: {gen :: non_neg_integer, [{non_neg_integer, row}]}
  @type cell_px :: {pos_integer, pos_integer} | nil
  @type mod :: :shift | :ctrl | :alt | :super
  @type key_event :: %{
          key: atom | binary,
          mods: [mod],
          event: :press | :release | :repeat,
          text: binary | nil
        }
  @type mouse_event :: %{
          kind: :press | :release | :move | :drag | :scroll,
          button:
            :left | :middle | :right | :wheel_up | :wheel_down | :wheel_left | :wheel_right | nil,
          x: non_neg_integer,
          y: non_neg_integer,
          mods: [mod],
          px: {number, number} | nil
        }
  @type cursor :: %{
          x: non_neg_integer,
          y: non_neg_integer,
          visible: boolean,
          blinking: boolean,
          shape: :block | :bar | :underline | :block_hollow
        }
  @type rgb :: {0..255, 0..255, 0..255}
  @type colors :: %{
          optional(:fg) => rgb | nil,
          optional(:bg) => rgb | nil,
          optional(:cursor) => rgb | nil,
          optional(:palette) => %{optional(0..255) => rgb}
        }
  @type point :: {non_neg_integer, non_neg_integer}

  @callback new(pos_integer, pos_integer, non_neg_integer) :: {:ok, vt}
  @callback resize(vt, pos_integer, pos_integer, cell_px) :: :ok
  @callback dirty_rows(vt) :: rows
  @callback full_rows(vt) :: rows
  @callback read_text(
              vt,
              :viewport | :screen | {:rows, Range.t()} | {:selection, point, point}
            ) :: binary
  @callback screen_rows(vt, non_neg_integer, non_neg_integer) :: [
              {non_neg_integer, row, boolean}
            ]
  @callback set_colors(vt, colors) :: :ok
  @callback set_color_scheme(vt, :dark | :light | nil) :: :ok
  @callback modify_other_keys(vt) :: boolean | {:stale, boolean}
  @callback scrollbar(vt) :: %{
              total: non_neg_integer,
              viewport: non_neg_integer,
              offset: non_neg_integer
            }
  @doc "`{cols, rows}` of the screen."
  @callback size(vt) :: {pos_integer, pos_integer}
  @callback scroll_to(vt, non_neg_integer) :: :ok
  @callback mode(vt, atom) :: boolean | {:stale, boolean}
  @callback kitty_keyboard_flags(vt) :: non_neg_integer | {:stale, non_neg_integer}
  @callback link_at(vt, non_neg_integer, non_neg_integer) ::
              nil | %{uri: binary, kind: :hyperlink | :text}
  @callback graphics_placements(vt) :: [HerdrScene.Scene.Graphic.t()]
  @callback graphics_image(vt, pos_integer) :: HerdrScene.Scene.Graphic.image() | nil
  @callback cursor(vt) :: cursor | nil
  @callback encode_key(vt, key_event) :: binary
  @callback encode_mouse(vt, mouse_event) :: binary | nil
  @callback encode_focus(vt, boolean) :: binary
  @doc "The primary screen's last `n` rows as VT, or `:alt_screen` while it is active."
  @callback tail_ansi(vt, non_neg_integer) :: binary | :alt_screen
end
