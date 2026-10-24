defmodule HerdrScene.Scene.Overlay do
  @moduledoc """
  Semantic overlay on a pane. Coordinates are pane-relative and inclusive.
  The client decides how to draw it (a terminal may use inverse or underline).

    * `:selection` - `%{from: {x, y}, to: {x, y}}`
    * `:dim` - `%{reason: :inactive}`
    * `:link_hover` - `%{id: non_neg_integer, from: {x, y}, to: {x, y}}`
    * `:scrollbar` - `%{total: n, viewport: n, offset: n}`
  """

  @type kind :: :selection | :dim | :link_hover | :scrollbar
  @type t :: %__MODULE__{kind: kind, args: map}

  @enforce_keys [:kind]
  defstruct [:kind, args: %{}]
end
