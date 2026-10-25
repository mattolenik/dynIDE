defmodule HerdrServer.Native.Vt do
  @moduledoc """
  One terminal emulator (ghostty) and its snapshot of packed rows
  (`HerdrScene.Cell`). Row reads come from the snapshot and never wait on the
  parser; `feed/2` is for tests and replay (live panes are fed by their `Pty`).
  """
  @behaviour HerdrServer.Kernel.Vt

  alias HerdrServer.Native

  @max_x 65_535
  @max_y 4_294_967_295

  @opaque vt :: reference
  @type gen :: non_neg_integer
  @type rows :: {gen, [{non_neg_integer, HerdrScene.Cell.row()}]}
  @type cell_px :: {pos_integer, pos_integer} | nil
  @type mode ::
          :cursor_keys
          | :origin
          | :wraparound
          | :cursor_blinking
          | :cursor_visible
          | :mouse_x10
          | :mouse_normal
          | :mouse_button
          | :mouse_any
          | :focus_events
          | :mouse_utf8
          | :mouse_sgr
          | :alternate_scroll
          | :mouse_sgr_pixels
          | :bracketed_paste
          | :synchronized_output
          | :grapheme_cluster
          | :color_scheme_report
          | :alt_screen
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

  @doc "True for a valid column or row count: an integer in 1..65535."
  defguard is_size(n) when is_integer(n) and n >= 1 and n <= 65_535

  @doc false
  @spec check_size!(term, term) :: :ok
  def check_size!(cols, rows) when is_size(cols) and is_size(rows), do: :ok

  def check_size!(cols, rows) do
    raise ArgumentError,
          "cols and rows must be integers in 1..65535, got: #{inspect(cols)} x #{inspect(rows)}"
  end

  @doc """
  Creates a `cols` x `rows` terminal keeping up to `max_scrollback` bytes of history.
  Raises `ArgumentError` for sizes outside 1..65535, and on a ghostty error.
  """
  @spec new(pos_integer, pos_integer, non_neg_integer) :: {:ok, vt}
  def new(cols, rows, max_scrollback) do
    check_size!(cols, rows)
    Native.vt_new(cols, rows, max_scrollback)
  end

  @doc """
  Complete terminal state (screens, scrollback, modes, unfinished escape) in
  ghostty's snapshot format. Raises `ErlangError` with the ghostty error on failure.
  """
  @spec encode_snapshot(vt) :: binary
  def encode_snapshot(vt), do: Native.vt_encode_snapshot(vt)

  @doc "Rebuilds a terminal from `encode_snapshot/1` output; its size comes from the snapshot."
  @spec restore(binary, non_neg_integer) :: {:ok, vt} | {:error, binary}
  def restore(bytes, max_scrollback), do: Native.vt_restore(bytes, max_scrollback)

  @doc "Parses `bytes` and refreshes the snapshot; returns the new generation. Tests and replay only."
  @spec feed(vt, binary) :: gen
  def feed(vt, bytes), do: Native.vt_feed(vt, bytes)

  @doc """
  Resizes the grid; `cell_px` is the pixel size of one cell (nil keeps the last one).
  Raises `ArgumentError` for sizes outside 1..65535, and on a ghostty error.
  """
  @spec resize(vt, pos_integer, pos_integer, cell_px) :: :ok
  def resize(vt, cols, rows, cell_px) do
    check_size!(cols, rows)
    Native.vt_resize(vt, cols, rows, cell_px)
  end

  @doc "Rows changed since the last `dirty_rows/1` call (or since a resubscribe reset)."
  @spec dirty_rows(vt) :: rows
  def dirty_rows(vt), do: Native.vt_dirty_rows(vt)

  @doc "The current generation (what `rows_since/2` returns first), without copying rows."
  @spec gen(vt) :: gen
  def gen(vt), do: Native.vt_gen(vt)

  @doc "Rows whose generation is newer than `gen`."
  @spec rows_since(vt, gen) :: rows
  def rows_since(vt, gen), do: Native.vt_rows_since(vt, gen)

  @doc "Every viewport row."
  @spec full_rows(vt) :: rows
  def full_rows(vt), do: Native.vt_full_rows(vt)

  @doc """
  Plain text of the viewport, the whole screen with scrollback, inclusive screen
  rows, or a selection between two inclusive screen points `{x, y}` (y counts rows
  from the top of history; either order; points past the screen clamp to it).
  Soft-wrapped lines are joined and trailing whitespace is trimmed.
  """
  @spec read_text(
          vt,
          :viewport | :screen | {:rows, Range.t()} | {:selection, point, point}
        ) :: binary
  def read_text(vt, range) when range in [:viewport, :screen],
    do: Native.vt_read_text(vt, range, 0, 0)

  def read_text(vt, {:rows, first..last//_}) when first >= 0 and last >= 0,
    do: Native.vt_read_text(vt, :rows, min(first, last), max(first, last))

  def read_text(vt, {:selection, {x1, y1}, {x2, y2}})
      when x1 >= 0 and y1 >= 0 and x2 >= 0 and y2 >= 0 do
    Native.vt_read_selection(
      vt,
      min(x1, @max_x),
      min(y1, @max_y),
      min(x2, @max_x),
      min(y2, @max_y)
    )
  end

  @doc """
  The last `n` rows of the primary screen's history plus screen as VT (SGR kept,
  soft wraps joined, trimmed; blank rows below the last content row skipped), `""`
  for `n = 0` or an empty screen, `:alt_screen` while the alternate screen is active.
  `n` is clamped to 10_000 rows (`MAX_TAIL_ROWS` in the kernel).
  """
  @spec tail_ansi(vt, non_neg_integer) :: binary | :alt_screen
  def tail_ansi(vt, n) when is_integer(n) and n >= 0, do: Native.vt_tail_ansi(vt, n)

  @doc """
  Inclusive screen rows `first..last` as `{row, packed_row, wrapped}`: at most
  1000 rows per call, rows past the end omitted. Packed cells carry glyph and
  width only (default colours, no attrs, no links); `wrapped` is true when the row
  soft-wraps into the next.
  """
  @spec screen_rows(vt, non_neg_integer, non_neg_integer) :: [
          {non_neg_integer, HerdrScene.Cell.row(), boolean}
        ]
  def screen_rows(vt, first, last) when first >= 0 and last >= 0,
    do: Native.vt_screen_rows(vt, min(first, @max_y), min(last, @max_y))

  @doc """
  Sets ghostty's default fg, bg and cursor colours (nil or missing unsets) and
  overlays `palette` entries on its built-in palette, so ghostty answers OSC
  10/11/12/4 queries itself. Raises `ArgumentError` on a malformed map.
  """
  @spec set_colors(vt, colors) :: :ok
  def set_colors(vt, colors) when is_map(colors), do: Native.vt_set_colors(vt, colors)

  @doc "The colour scheme ghostty reports for `CSI ? 996 n`; nil leaves it unanswered."
  @spec set_color_scheme(vt, :dark | :light | nil) :: :ok
  def set_color_scheme(vt, scheme) when scheme in [:dark, :light, nil],
    do: Native.vt_set_color_scheme(vt, scheme)

  @doc "Whether the child enabled xterm modifyOtherKeys; `{:stale, v}` as in `mode/2`."
  @spec modify_other_keys(vt) :: boolean | {:stale, boolean}
  def modify_other_keys(vt), do: Native.vt_modify_other_keys(vt)

  @doc "Scrollback position, in rows."
  @spec scrollbar(vt) :: %{
          total: non_neg_integer,
          viewport: non_neg_integer,
          offset: non_neg_integer
        }
  def scrollbar(vt), do: Native.vt_scrollbar(vt)

  @doc "`{cols, rows}` as of the last snapshot."
  @spec size(vt) :: {pos_integer, pos_integer}
  def size(vt), do: Native.vt_size(vt)

  @doc "Scrolls the viewport to `offset` rows from the top of the scrollback. Raises on a ghostty error."
  @spec scroll_to(vt, non_neg_integer) :: :ok
  def scroll_to(vt, offset), do: Native.vt_scroll_to(vt, offset)

  @doc """
  Current value of a terminal mode. `{:stale, v}` is the snapshot value, returned
  when the parser holds the terminal. An unknown mode raises `ArgumentError`.
  """
  @spec mode(vt, mode) :: boolean | {:stale, boolean}
  def mode(vt, mode), do: Native.vt_mode(vt, mode)

  @doc "Kitty keyboard protocol flags; `{:stale, v}` as in `mode/2`."
  @spec kitty_keyboard_flags(vt) :: non_neg_integer | {:stale, non_neg_integer}
  def kitty_keyboard_flags(vt), do: Native.vt_kitty_keyboard_flags(vt)

  @doc "The OSC 8 hyperlink or detected URL at viewport cell (`x`, `y`)."
  @spec link_at(vt, non_neg_integer, non_neg_integer) ::
          nil | %{uri: binary, kind: :hyperlink | :text}
  def link_at(vt, x, y), do: Native.vt_link_at(vt, x, y)

  @doc """
  Kitty graphics placements visible in the viewport (`HerdrScene.Scene.Graphic` maps,
  sorted by z). Reads the last snapshot, so it never waits on the reader; no pixel data.
  """
  @spec graphics_placements(vt) :: [HerdrScene.Scene.Graphic.t()]
  def graphics_placements(vt), do: Native.vt_graphics_placements(vt)

  @doc "Copies image `image_id`'s pixels; nil when it is gone, unplaced, or has no data."
  @spec graphics_image(vt, pos_integer) :: HerdrScene.Scene.Graphic.image() | nil
  def graphics_image(vt, image_id), do: Native.vt_graphics_image(vt, image_id)

  @doc "The cursor, or nil when it is outside the viewport."
  @spec cursor(vt) :: cursor | nil
  def cursor(vt), do: Native.vt_cursor(vt)

  @doc "Bytes to send to the child for a key event under the current modes. Invalid events raise `ArgumentError`."
  @spec encode_key(vt, key_event) :: binary
  def encode_key(vt, event), do: Native.vt_encode_key(vt, event)

  @doc "Bytes for a mouse event, or nil when the child is not tracking it. Invalid events raise `ArgumentError`."
  @spec encode_mouse(vt, mouse_event) :: binary | nil
  def encode_mouse(vt, event), do: Native.vt_encode_mouse(vt, event)

  @doc "Focus in/out report bytes; empty unless the child enabled focus events."
  @spec encode_focus(vt, boolean) :: binary
  def encode_focus(vt, focused), do: Native.vt_encode_focus(vt, focused)
end
