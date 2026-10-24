defmodule HerdrScene.Scene.Overlay do
  @moduledoc """
  Semantic overlay on a pane. Coordinates are pane-relative and inclusive.
  The client decides how to draw it (a terminal may use inverse or underline).

    * `:selection` - `%{from: {x, y}, to: {x, y}}`
    * `:dim` - `%{reason: :inactive}`
    * `:link_hover` - `%{id: non_neg_integer, from: {x, y}, to: {x, y}}`; id 0 is a
      detected text URL, `from`/`to` a stream range that may wrap rows
    * `:scrollbar` - `%{total: n, viewport: n, offset: n}` in rows; `offset` is rows from
      the top of history to the viewport top; emitted only while scrolled back
    * `:copy_cursor` - `%{at: {x, y}}`
    * `:search_match` - `%{from: {x, y}, to: {x, y}, current: boolean}`
  """

  @type kind :: :selection | :dim | :link_hover | :scrollbar | :copy_cursor | :search_match
  @type t :: %__MODULE__{kind: kind, args: map}

  @enforce_keys [:kind]
  defstruct [:kind, args: %{}]
end
