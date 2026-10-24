defmodule HerdrServer.Kernel.Vt do
  @moduledoc "Terminal state kernel (design.md, Native.Vt). `cursor/1` is a recorded addition."

  @type vt :: term
  @type row :: HerdrScene.Cell.row()
  @type rows :: {gen :: integer, [{non_neg_integer, row}]}

  @callback new(pos_integer, pos_integer, non_neg_integer) :: {:ok, vt}
  @callback resize(vt, pos_integer, pos_integer, {pos_integer, pos_integer} | nil) :: :ok
  @callback dirty_rows(vt) :: rows
  @callback full_rows(vt) :: rows
  @callback read_text(vt, :viewport | :screen | {:rows, Range.t()}) :: binary
  @callback scrollbar(vt) :: %{total: non_neg_integer, viewport: non_neg_integer, offset: integer}
  @callback scroll_to(vt, non_neg_integer) :: :ok
  @callback mode(vt, integer) :: boolean | {:stale, boolean}
  @callback kitty_keyboard_flags(vt) :: integer
  @callback link_at(vt, non_neg_integer, non_neg_integer) :: nil | %{uri: binary, kind: atom}
  @callback encode_key(vt, HerdrScene.Event.t()) :: binary
  @callback encode_mouse(vt, HerdrScene.Event.t()) :: binary | nil
  @callback encode_focus(vt, boolean) :: binary
  @callback graphics_placements(vt, term) :: [term]
  @callback cursor(vt) :: %{
              x: non_neg_integer,
              y: non_neg_integer,
              shape: :block | :underline | :bar,
              visible: boolean
            }
end
