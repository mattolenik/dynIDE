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
    * A drag hit with role `:tab` or `:item` (a reorderable tab or workspace) is a click
      first (M13 ruling 18: the press acts): its press emits `:click` and remembers a
      `reorder` grab; the first motion makes it held, then `:drag` / `:drop` as above, each
      with `over`, the topmost hit path under the pointer (nil over none). A release
      without motion emits nothing more.
    * Right / middle press emit `:right_click` / `:middle_click`; wheel up / down emit
      `:scroll_up` / `:scroll_down`. A move over a hit passes through unchanged (outside
      every pane the server only uses it to clear a link hover); other events over a hit
      are swallowed.
    * Other events over no hit pass through unchanged.
    * A `:pane` hit (a popup pane's box, `Render.Chrome`) counts as no hit: it only
      hides the hits under it.
  """

  @double_ms 350

  @type grab ::
          %{
            required(:path) => [term] | nil,
            required(:at) => integer,
            required(:held) => boolean,
            required(:down) => boolean,
            optional(:reorder) => true
          }
          | :pass
          | nil

  @reorder [:tab, :item]

  @spec route([map], grab, tuple, integer) :: {[tuple], grab}
  def route(hits, grab, {:mouse, m} = ev, now) do
    grab =
      if stale?(grab, hits),
        do: grab |> Map.merge(%{held: false, down: true}) |> Map.delete(:reorder),
        else: grab

    held(grab, m, ev, hits, now)
  end

  def route(_hits, grab, ev, _now), do: {[ev], grab}

  @doc "The path of the topmost hit under `{x, y}` when its role is hoverable, else nil."
  @spec hover([map], integer, integer) :: [term] | nil
  def hover(hits, x, y) do
    case at(hits, x, y) do
      %{role: role, path: path} when role in [:item, :tab] -> path
      _ -> nil
    end
  end

  defp stale?(%{held: true, path: p}, hits), do: not Enum.any?(hits, &(&1.path == p))
  defp stale?(_grab, _hits), do: false

  defp held(%{held: true, path: p} = g, %{kind: :drag} = m, _ev, hits, _now),
    do: {[chrome(p, :drag, m, over(g, hits, m))], g}

  defp held(%{held: true, path: p} = g, %{kind: :release} = m, _ev, hits, _now),
    do: {[chrome(p, :drop, m, over(g, hits, m))], Map.merge(g, %{held: false, down: false})}

  # a reorder press already clicked: its first motion starts the drag
  defp held(%{down: true, reorder: true} = g, %{kind: :drag} = m, ev, hits, now),
    do: held(%{g | held: true}, m, ev, hits, now)

  defp held(:pass, %{kind: :drag}, ev, _hits, _now), do: {[ev], :pass}
  defp held(:pass, %{kind: :release}, ev, _hits, _now), do: {[ev], nil}
  defp held(%{down: true} = g, %{kind: :drag}, _ev, _hits, _now), do: {[], g}
  defp held(%{down: true} = g, %{kind: :release}, _ev, _hits, _now), do: {[], %{g | down: false}}

  defp held(grab, m, ev, hits, now) do
    case at(hits, m.x, m.y) do
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

      hit.drag and hit.role in @reorder ->
        {[chrome(p, :click, m)], %{path: p, at: now, held: false, down: true, reorder: true}}

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

  defp chrome(path, kind, m, :none), do: chrome(path, kind, m)
  defp chrome(path, kind, m, over), do: {:chrome, path, {kind, %{x: m.x, y: m.y, over: over}}}

  # only a reorder drag names the hit under the pointer
  defp over(%{reorder: true}, hits, m) do
    case at(hits, m.x, m.y) do
      %{path: p} -> p
      nil -> nil
    end
  end

  defp over(_grab, _hits, _m), do: :none

  # the topmost hit under the point; a popup pane's box hides the ones under it
  defp at(hits, x, y) do
    case Enum.find(hits, &inside?(&1.rect, x, y)) do
      %{role: :pane} -> nil
      hit -> hit
    end
  end

  defp inside?(r, x, y), do: x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
