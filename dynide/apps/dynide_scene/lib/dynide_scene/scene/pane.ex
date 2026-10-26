defmodule DynideScene.Scene.Pane do
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

  `graphics` lists the pane's kitty image placements (`DynideScene.Scene.Graphic`), sorted
  by z, pane-relative and unclipped: the client clips them to `rect` and its own chrome.

  `layer` is `:base` (default: tiled panes, disjoint from each other) or `:popup` (a
  floating pane, e.g. `App.Modal.Popup`). A client draws `:popup` panes, with their
  border, after every `:base` pane and after an open modal's dim, so the dim never
  applies to them; chrome top-layer nodes (dialogs, toasts) still draw over them. Popup
  panes may overlap `:base` panes: there the popup wins for cells, pointer hits and
  kitty graphics (a `:base` pane's placements are clipped out of popup rects). Among
  popups, later in `panes` is on top. The cursor stays the focused pane's.
  """

  alias DynideScene.Scene.{Graphic, Overlay}

  @type rect :: DynideScene.Scene.rect()
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
          graphics: [Graphic.t()],
          layer: :base | :popup
        }

  @enforce_keys [:id, :rect, :rows]
  defstruct [:id, :rect, :border, :rows, :cursor, overlays: [], graphics: [], layer: :base]

  @layers [:base, :popup]

  @spec layers() :: [atom]
  def layers, do: @layers
end
