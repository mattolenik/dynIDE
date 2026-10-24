defmodule HerdrTerm.Client.Term.Hit do
  @moduledoc """
  Chrome hit testing (pure): turns mouse events over chrome hits into
  `{:chrome, path, {kind, %{x, y}}}` and passes every other event through unchanged.

  `hits` are `Render.Chrome` hits (`%{rect, path, role, drag}`), topmost first. The
  grab is `nil` or `%{path, at, held}`: `held: true` is an active drag grab, `held:
  false` only remembers the last left press (`at`, ms) for double clicks.

    * Left press on a hit: `:double_click` when the previous left press hit the same
      path within 350 ms (and no grab starts), else a drag hit grabs (emits nothing)
      and any other hit emits `:click`.
    * With a held grab, `:drag` emits `:drag` and release emits `:drop` (and ends the
      grab) for the grabbed path, wherever the pointer is. A held grab whose path is no
      longer in `hits` is dropped first ("stale grab").
    * Right / middle press emit `:right_click` / `:middle_click`; wheel up / down emit
      `:scroll_up` / `:scroll_down`; other events over a hit are swallowed.
    * Events over no hit pass through unchanged.
  """

  @double_ms 350

  @type grab :: %{path: [term], at: integer, held: boolean} | nil

  @spec route([map], grab, tuple, integer) :: {[tuple], grab}
  def route(hits, grab, {:mouse, m} = ev, now) do
    grab = if stale?(grab, hits), do: nil, else: grab
    held(grab, m, ev, hits, now)
  end

  def route(_hits, grab, ev, _now), do: {[ev], grab}

  defp stale?(%{held: true, path: p}, hits), do: not Enum.any?(hits, &(&1.path == p))
  defp stale?(_grab, _hits), do: false

  defp held(%{held: true, path: p} = g, %{kind: :drag} = m, _ev, _hits, _now),
    do: {[chrome(p, :drag, m)], g}

  defp held(%{held: true, path: p} = g, %{kind: :release} = m, _ev, _hits, _now),
    do: {[chrome(p, :drop, m)], %{g | held: false}}

  defp held(grab, m, ev, hits, now) do
    case Enum.find(hits, &inside?(&1.rect, m.x, m.y)) do
      nil -> {[ev], grab}
      hit -> over(hit, m, release(grab), now)
    end
  end

  defp release(%{held: true} = g), do: %{g | held: false}
  defp release(g), do: g

  defp over(%{path: p} = hit, %{kind: :press, button: :left} = m, last, now) do
    cond do
      last != nil and last.path == p and now - last.at <= @double_ms ->
        {[chrome(p, :double_click, m)], nil}

      hit.drag ->
        {[], %{path: p, at: now, held: true}}

      true ->
        {[chrome(p, :click, m)], %{path: p, at: now, held: false}}
    end
  end

  defp over(%{path: p}, %{kind: :press, button: :right} = m, last, _now),
    do: {[chrome(p, :right_click, m)], last}

  defp over(%{path: p}, %{kind: :press, button: :middle} = m, last, _now),
    do: {[chrome(p, :middle_click, m)], last}

  defp over(%{path: p}, %{kind: :scroll, button: :wheel_up} = m, last, _now),
    do: {[chrome(p, :scroll_up, m)], last}

  defp over(%{path: p}, %{kind: :scroll, button: :wheel_down} = m, last, _now),
    do: {[chrome(p, :scroll_down, m)], last}

  defp over(_hit, _m, last, _now), do: {[], last}

  defp chrome(path, kind, m), do: {:chrome, path, {kind, %{x: m.x, y: m.y}}}

  defp inside?(r, x, y), do: x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
