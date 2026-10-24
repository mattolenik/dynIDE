defmodule HerdrScene.Scene.Pane do
  @moduledoc """
  A pane in the scene. `rect` is the content rect: exactly the terminal grid,
  rows map 1:1. The optional `border` carries its own outer rect.

  `rows` is `{:ref, pane_id, gen}` (client resolves packed rows from the row
  cache; `gen` is the layout generation) or `{:inline, [{n, packed_row}]}`.
  `cursor` is relative to `rect`.
  """

  alias HerdrScene.Scene.Overlay

  @type rect :: HerdrScene.Scene.rect()
  @type border :: %{rect: rect, edges: [:top | :bottom | :left | :right], title: binary | nil}
  @type rows ::
          {:ref, pos_integer, non_neg_integer} | {:inline, [{non_neg_integer, binary}]}
  @type t :: %__MODULE__{
          id: pos_integer,
          rect: rect,
          border: border | nil,
          rows: rows,
          cursor: %{x: non_neg_integer, y: non_neg_integer, shape: atom, visible: boolean} | nil,
          overlays: [Overlay.t()],
          graphics: [map]
        }

  @enforce_keys [:id, :rect, :rows]
  defstruct [:id, :rect, :border, :rows, :cursor, overlays: [], graphics: []]
end
