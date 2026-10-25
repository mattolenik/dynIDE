defmodule HerdrScene.Scene.Pane do
  @moduledoc """
  A pane in the scene. `rect` is the content rect: exactly the terminal grid,
  rows map 1:1. The optional `border` carries its own outer rect.

  `rows` is `{:ref, pane_id, layout_gen}` (client resolves packed rows from the
  row cache) or `{:inline, [{n, packed_row}]}` (a partial update: the listed
  rows replace those rows of the client's cache, unlisted rows keep it, blank when
  none; an empty list changes nothing).

  Generations: `layout_gen` counts the pane's resizes (contract decision 2:
  "bumped on resize or respawn"; M3 has no respawn, a restarted pane server
  shows up as damage instead). A client re-fetches a ref pane when its
  `layout_gen` changes or the pane is new. The `gen` in `{:damage, id, gen}`,
  `{:rows, id, gen, _}` and the row cache is the pane's content generation.
  The two are unrelated; never compare one with the other.

  `cursor` is relative to `rect`. Inline scenes carry it; ref scenes leave it
  nil (the client reads it from the row cache with the rows). `shape` is `:block`,
  `:underline`, `:bar` or `:default` (the host terminal's own cursor style); `blinking`
  is optional.
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
