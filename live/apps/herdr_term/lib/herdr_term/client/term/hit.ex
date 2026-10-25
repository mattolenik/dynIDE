defmodule HerdrTerm.Client.Term.Hit do
  @moduledoc """
  Chrome hit testing (pure): turns mouse events over chrome hits into
  `{:chrome, path, {kind, %{x, y}}}` and passes every other event through unchanged.

  `hits` are `Render.Chrome` hits (`%{rect, path, role, drag}`), topmost first. The
  grab is `nil`, `:pass`, or `%{path, at, held, down}`: `held: true` is an active drag
  grab; `held: false` remembers the last left press on a hit (`at`, ms) for double
  clicks, with `down: true` until its release.

    * Left press on a hit: `:double_click` when the previous left press hit the same
      path within 350 ms (and no grab starts), else a drag hit grabs (emits nothing)
      and any other hit emits `:click`. Drags and the release that follow a press on a
      hit are swallowed wherever the pointer is.
    * With a held grab, `:drag` emits `:drag` and release emits `:drop` (and ends the
      grab) for the grabbed path, wherever the pointer is. A held grab whose path is no
      longer in `hits` is dropped first ("stale grab"); its drags and release are
      swallowed, never passed to a pane without their press.
    * Left press over no hit passes through and sets the `:pass` grab: drags and the
      release pass through unchanged until that release, even over a hit (a pane
      selection or a program's mouse drag crossing chrome).
    * Right / middle press emit `:right_click` / `:middle_click`; wheel up / down emit
      `:scroll_up` / `:scroll_down`. A move over a hit passes through unchanged (outside
      every pane the server only uses it to clear a link hover); other events over a hit
      are swallowed.
    * Other events over no hit pass through unchanged.
  """

  @double_ms 350

  @type grab :: %{path: [term] | nil, at: integer, held: boolean, down: boolean} | :pass | nil

  @spec route([map], grab, tuple, integer) :: {[tuple], grab}
  def route(hits, grab, {:mouse, m} = ev, now) do
    grab = if stale?(grab, hits), do: Map.merge(grab, %{held: false, down: true}), else: grab
    held(grab, m, ev, hits, now)
  end

  def route(_hits, grab, ev, _now), do: {[ev], grab}

  defp stale?(%{held: true, path: p}, hits), do: not Enum.any?(hits, &(&1.path == p))
  defp stale?(_grab, _hits), do: false

  defp held(%{held: true, path: p} = g, %{kind: :drag} = m, _ev, _hits, _now),
    do: {[chrome(p, :drag, m)], g}

  defp held(%{held: true, path: p} = g, %{kind: :release} = m, _ev, _hits, _now),
    do: {[chrome(p, :drop, m)], Map.merge(g, %{held: false, down: false})}

  defp held(:pass, %{kind: :drag}, ev, _hits, _now), do: {[ev], :pass}
  defp held(:pass, %{kind: :release}, ev, _hits, _now), do: {[ev], nil}
  defp held(%{down: true} = g, %{kind: :drag}, _ev, _hits, _now), do: {[], g}
  defp held(%{down: true} = g, %{kind: :release}, _ev, _hits, _now), do: {[], %{g | down: false}}

  defp held(grab, m, ev, hits, now) do
    case Enum.find(hits, &inside?(&1.rect, m.x, m.y)) do
      nil when m.kind == :press and m.button == :left -> {[ev], :pass}
      nil -> {[ev], grab}
      _hit when m.kind == :move -> {[ev], grab}
      hit -> over(hit, m, release(grab), now)
    end
  end

  defp release(%{held: true} = g), do: %{g | held: false}
  defp release(g), do: g

  defp over(%{path: p} = hit, %{kind: :press, button: :left} = m, last, now) do
    cond do
      match?(%{path: ^p}, last) and now - last.at <= @double_ms ->
        {[chrome(p, :double_click, m)], %{path: nil, at: now, held: false, down: true}}

      hit.drag ->
        {[], %{path: p, at: now, held: true, down: false}}

      true ->
        {[chrome(p, :click, m)], %{path: p, at: now, held: false, down: true}}
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
