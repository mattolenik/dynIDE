defmodule HerdrServer.Native.Vt do
  @moduledoc """
  One terminal emulator (ghostty) and its snapshot of packed rows
  (`HerdrScene.Cell`). Row reads come from the snapshot and never wait on the
  parser; `feed/2` is for tests and replay (live panes are fed by their `Pty`).
  """
  @behaviour HerdrServer.Kernel.Vt

  alias HerdrServer.Native

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

  @doc "Rows whose generation is newer than `gen`."
  @spec rows_since(vt, gen) :: rows
  def rows_since(vt, gen), do: Native.vt_rows_since(vt, gen)

  @doc "Every viewport row."
  @spec full_rows(vt) :: rows
  def full_rows(vt), do: Native.vt_full_rows(vt)

  @doc "Plain text of the viewport, the whole screen with scrollback, or inclusive screen rows."
  @spec read_text(vt, :viewport | :screen | {:rows, Range.t()}) :: binary
  def read_text(vt, range) when range in [:viewport, :screen],
    do: Native.vt_read_text(vt, range, 0, 0)

  def read_text(vt, {:rows, first..last//_}) when first >= 0 and last >= 0,
    do: Native.vt_read_text(vt, :rows, min(first, last), max(first, last))

  @doc "Scrollback position, in rows."
  @spec scrollbar(vt) :: %{
          total: non_neg_integer,
          viewport: non_neg_integer,
          offset: non_neg_integer
        }
  def scrollbar(vt), do: Native.vt_scrollbar(vt)

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

  @doc "Kitty graphics placements visible in the viewport."
  @spec graphics_placements(vt) :: [map]
  def graphics_placements(vt), do: Native.vt_graphics_placements(vt)

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
