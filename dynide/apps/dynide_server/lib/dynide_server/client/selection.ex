defmodule DynideServer.Client.Selection do
  @moduledoc """
  Pure per-client stream selection on one pane (herdr selection.rs).

  `anchor` is where the gesture started and `head` where the pointer is; both are
  `{col, row}` with `row` an absolute screen row (viewport row + `scroll.offset`), so
  a selection stays on its text while the pane scrolls. `unit` is `:char`, `:word`
  (anchor/head already word-expanded by the caller, then treated like `:char`) or
  `:line` (full rows). `shown` is false between the press and the first drag.

  Coordinates are stored as the pointer gave them; `:line` is widened only when a
  width is known: `range/1` orders the endpoints, `range/2` also widens `:line` to
  `{0, y1}..{w - 1, y2}`. Use `range/2` for copying (`Native.Vt.read_text`).
  `overlay/4` is the `:selection` overlay for the current viewport, clipped to it.
  """

  alias DynideScene.Scene.Overlay

  @type pos :: {non_neg_integer, non_neg_integer}
  @type t :: %__MODULE__{
          pane: term,
          anchor: pos | nil,
          head: pos | nil,
          unit: :char | :word | :line,
          shown: boolean
        }

  defstruct pane: nil, anchor: nil, head: nil, unit: :char, shown: false

  @doc "Anchor and head ordered as `{first, last}` in stream order (absolute rows)."
  @spec range(t) :: {pos, pos}
  def range(%__MODULE__{anchor: {ax, ay} = a, head: {hx, hy} = h}),
    do: if({ay, ax} <= {hy, hx}, do: {a, h}, else: {h, a})

  @doc "`range/1`, with a `:line` selection widened to full rows of width `w`."
  @spec range(t, pos_integer) :: {pos, pos}
  def range(%__MODULE__{unit: :line} = sel, w) do
    {{_, y1}, {_, y2}} = range(sel)
    {{0, y1}, {w - 1, y2}}
  end

  def range(sel, _w), do: range(sel)

  @doc """
  The `:selection` overlay in viewport coordinates of a `w` x `h` pane scrolled to
  `scroll.offset`, clipped to it (starting above it starts at `{0, 0}`, ending below
  it ends at `{w - 1, h - 1}`), or nil when hidden or entirely outside.
  """
  @spec overlay(t | nil, %{offset: non_neg_integer}, non_neg_integer, non_neg_integer) ::
          Overlay.t() | nil
  def overlay(%__MODULE__{shown: true, anchor: {_, _}, head: {_, _}} = sel, %{offset: off}, w, h)
      when w > 0 and h > 0 do
    {{x1, y1}, {x2, y2}} = range(sel, w)
    {v1, v2} = {y1 - off, y2 - off}

    if v2 < 0 or v1 > h - 1 do
      nil
    else
      from = if v1 < 0, do: {0, 0}, else: {min(x1, w - 1), v1}
      to = if v2 > h - 1, do: {w - 1, h - 1}, else: {min(x2, w - 1), v2}
      %Overlay{kind: :selection, args: %{from: from, to: to}}
    end
  end

  def overlay(_sel, _scroll, _w, _h), do: nil
end
