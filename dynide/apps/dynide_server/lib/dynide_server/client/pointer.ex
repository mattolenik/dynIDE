defmodule DynideServer.Client.Pointer do
  @moduledoc """
  Pure per-client pointer resolver (herdr's client mouse handling: wheel routing,
  selection, double-click words, ctrl+click links, link hover, scrollbar drag).
  `resolve/3` takes this client's pointer state, one `{:mouse, m}` event in scene
  coordinates and a context the session builds, and returns the new state and actions
  for `Client.PointerIo`. It does no I/O.

  State (all nil by default):

    * `selection` - `%Client.Selection{}` (absolute rows), shown or not
    * `hover` - the ctrl-hovered link: `Links.at/4`'s map plus `pane` and the scroll
      `offset` it was found at, i.e. `%{pane, offset, id, from, to}` (OSC 8) or
      `%{pane, offset, id: 0, url, from, to}` (text), with viewport coordinates (`to`
      inclusive)
    * `press` - a left-button gesture on a non-tracking pane:
      `%{pane, x, row, at, word: nil | {first, last, row}, moved: boolean}`
    * `last_click` - `%{pane, x, row, at}` of the last plain click (double-click)
    * `drag` - `%{kind: :scrollbar, pane, grab}` while dragging a scrollbar thumb
    * `swallow_up` - `%{pane, local, tracking}`: a consumed ctrl+click or menu press; its
      drags and release are dropped. When the kernel finds no link, `PointerIo` replays
      `local` (the pane-relative press) to a tracking child and stops swallowing; a
      non-tracking pane drops the click.
    * `autoscroll` - `%{pane, dir: :up | :down}` while a drag holds an edge
    * `strip` - the config's right-click passthrough mods while that gesture runs; they
      are removed from its drags and release
    * `alt` - `{pane, alt_screen?}` of the selection's (or hover's) pane when last seen;
      `facts/3` clears both when it toggles

  `ctx`: `%{panes: [%{id, rect}], focused, info: %{id => %{tracking, any_motion,
  alt_screen, alternate_scroll, scroll: %{total, viewport, offset}, rows, right_click}},
  now_ms, scroll_lines, copy_on_select, right_click_modifier}`; `info` holds the pane
  under the pointer and the gesture's pane (a pane without info is treated as gone: the
  event is forwarded).

  Actions: `{:forward, ev}`, `{:focus, id}`, `{:scroll, id, delta}`,
  `{:scroll_top, id, row}`, `{:keys, id, [key_event]}`, `{:copy, id, from, to}`,
  `{:open, id, %{id, x, y} | %{url}}`, `{:menu, id, %{x, y}}` (a right press opens the
  pane menu), `{:autoscroll, id, dir}`, `:autoscroll_stop`,
  `{:expire_selection, ms}` (clear the kept word highlight after `ms` if unchanged)
  and `:repaint` (selection or hover changed).

  Like herdr, a selection and hover are cleared when the pane leaves the scene or is
  resized (`prune/3`), when its alternate screen toggles (`facts/3`) and when app focus
  moves to another pane (`focus_moved/3`); a hover also when the pane scrolls.
  """

  alias DynideScene.{Cell, Event}
  alias DynideServer.Client.{Links, Selection, Words}

  defstruct selection: nil,
            hover: nil,
            press: nil,
            last_click: nil,
            drag: nil,
            swallow_up: nil,
            autoscroll: nil,
            alt: nil,
            strip: nil

  @type t :: %__MODULE__{}

  @double_ms 350
  @keep_ms 500

  @doc "Resolves one mouse event; see the moduledoc."
  @spec resolve(t, tuple, map) :: {t, [term]}
  def resolve(p, {:mouse, m} = ev, ctx) do
    p = Map.merge(%__MODULE__{}, p)
    {new, actions} = route(%{p | hover: nil}, ev, m, ctx)
    {seen(new, ctx), repaint(p, new, actions)}
  end

  # the alternate-screen state of the selection's (or hover's) pane, as last seen
  defp seen(p, ctx) do
    case p.selection || p.hover do
      %{pane: id} ->
        case ctx.info[id] do
          %{alt_screen: alt} -> %{p | alt: {id, alt}}
          _ -> p
        end

      nil ->
        %{p | alt: nil}
    end
  end

  @doc """
  Pane `id`'s facts changed (`%{alt_screen: boolean}`, optionally `offset`, the live
  scroll offset): an alternate-screen toggle clears the selection, hover and gesture
  on that pane; another scroll offset clears its hover (the selection is in absolute
  rows and survives scrolling).
  """
  @spec facts(t, term, map) :: t
  def facts(p, id, facts) do
    p = Map.merge(%__MODULE__{}, p)

    p =
      case p.alt do
        {^id, alt} when alt != facts.alt_screen ->
          %{p | selection: nil, hover: nil, press: nil, autoscroll: nil, alt: nil}

        _ ->
          p
      end

    case p.hover do
      %{pane: ^id, offset: off} when is_map_key(facts, :offset) and off != facts.offset ->
        %{p | hover: nil}

      _ ->
        p
    end
  end

  @doc "App focus moved from `old` to `new`: a selection or hover on another pane is cleared."
  @spec focus_moved(t, term, term) :: t
  def focus_moved(p, old, new) do
    p = Map.merge(%__MODULE__{}, p)

    if old == new or new == nil do
      p
    else
      p = if match?(%{pane: ^new}, p.selection), do: p, else: %{p | selection: nil, press: nil}
      if match?(%{pane: ^new}, p.hover), do: p, else: %{p | hover: nil}
    end
  end

  @doc "One autoscroll step (every 30 ms while `autoscroll` is set): one line and extend."
  @spec tick(t, map) :: {t, [term]}
  def tick(%{autoscroll: %{pane: id, dir: dir}, press: %{pane: id} = press} = p, ctx) do
    p = Map.merge(%__MODULE__{}, p)

    case pane(ctx, id) do
      {rect, info} -> step(p, press, dir, rect, info)
      nil -> {%{p | autoscroll: nil}, [:autoscroll_stop]}
    end
  end

  def tick(p, _ctx), do: {%{Map.merge(%__MODULE__{}, p) | autoscroll: nil}, [:autoscroll_stop]}

  defp step(p, press, dir, rect, info) do
    delta = if dir == :up, do: -1, else: 1
    off = info.scroll.offset
    new_off = clamp(off + delta, 0, max_offset(info.scroll))
    vy = if dir == :up, do: 0, else: rect.h - 1
    hx = if p.selection, do: elem(p.selection.head, 0), else: press.x

    if new_off == off do
      # at the end of the history: stop (a later edge drag re-arms)
      {%{p | autoscroll: nil}, [:autoscroll_stop]}
    else
      new = select(p, press, {hx, vy + new_off}, info)
      {new, repaint(p, new, [{:scroll, press.pane, delta}])}
    end
  end

  @doc """
  Drops pointer state whose pane is not in `new` scene or whose rect size differs from
  the `old` scene's (herdr clears a selection on resize or close). Scenes are anything
  with `panes: [%{id, rect}]`; `old` may be nil.
  """
  @spec prune(t, map | nil, map) :: t
  def prune(p, old, new) do
    p = Map.merge(%__MODULE__{}, p)
    was = sizes(old)
    now = sizes(new)
    keep? = &(Map.has_key?(now, &1) and Map.get(was, &1, now[&1]) == now[&1])

    Enum.reduce([:selection, :hover, :press, :last_click, :drag, :autoscroll], p, fn k, acc ->
      if stale?(Map.get(acc, k), keep?), do: Map.put(acc, k, nil), else: acc
    end)
  end

  defp stale?(%{pane: id}, keep?), do: not keep?.(id)
  defp stale?(_none, _keep?), do: false

  defp sizes(%{panes: panes}), do: Map.new(panes, &{&1.id, {&1.rect.w, &1.rect.h}})
  defp sizes(_), do: %{}

  # --- routing ---

  defp route(%{swallow_up: s} = p, _ev, %{kind: k}, _ctx)
       when s != nil and k in [:drag, :release],
       do: {if(k == :release, do: %{p | swallow_up: nil}, else: p), []}

  defp route(%{strip: mods} = p, _ev, %{kind: k} = m, _ctx)
       when mods != nil and k in [:drag, :release],
       do:
         {if(k == :release, do: %{p | strip: nil}, else: p),
          [{:forward, {:mouse, %{m | mods: m.mods -- mods}}}]}

  defp route(%{drag: %{kind: :scrollbar}} = p, ev, %{kind: k} = m, ctx)
       when k in [:drag, :release],
       do: scrollbar_drag(p, ev, m, ctx)

  defp route(%{press: press} = p, ev, %{kind: k} = m, ctx)
       when press != nil and k in [:drag, :release, :scroll] do
    case pane(ctx, press.pane) do
      nil -> {%{p | press: nil, autoscroll: nil}, [{:forward, ev}]}
      {rect, info} -> gesture(p, ev, m, rect, info, ctx)
    end
  end

  defp route(p, ev, m, ctx) do
    case hit(ctx, m) do
      nil ->
        p = if left_press?(m), do: %{p | selection: nil}, else: p
        {p, [{:forward, ev}]}

      {id, rect} ->
        case ctx.info[id] do
          nil -> {p, [{:forward, ev}]}
          info -> on_pane(p, ev, m, id, rect, info, ctx)
        end
    end
  end

  defp on_pane(p, ev, %{kind: :scroll} = m, id, _rect, info, ctx),
    do: wheel(p, ev, m, id, info, ctx)

  defp on_pane(p, ev, %{kind: :move} = m, id, rect, info, _ctx) do
    link = if :ctrl in m.mods, do: link(info, rect, m.x - rect.x, m.y - rect.y)
    p = %{p | hover: link && Map.merge(link, %{pane: id, offset: info.scroll.offset})}
    {p, if(info.tracking and info.any_motion, do: [{:forward, ev}], else: [])}
  end

  defp on_pane(p, ev, %{kind: :press, button: :left} = m, id, rect, info, ctx) do
    {vx, vy} = {m.x - rect.x, m.y - rect.y}
    link = if :ctrl in m.mods, do: link(info, rect, vx, vy)
    p = %{p | selection: nil}

    cond do
      link != nil ->
        local = {:mouse, %{m | x: vx, y: vy}}
        swallow = %{pane: id, local: local, tracking: info.tracking}

        {%{p | swallow_up: swallow, press: nil},
         [{:open, id, Map.put(target(link, vx, vy), :mods, m.mods)}]}

      scrollbar?(info, rect, vx) ->
        scrollbar_press(p, id, rect, info, vy, ctx)

      info.tracking ->
        {p, [{:forward, ev}]}

      true ->
        press(p, m, id, info, vx, vy, ctx)
    end
  end

  # herdr: a right-click opens the pane menu unless it goes to a mouse-tracking program:
  # plain on a pane set to `:pane`, or with exactly the config's modifier, which is
  # stripped from the press and the gesture that follows. The menu press's drags and
  # release are swallowed.
  defp on_pane(p, ev, %{kind: :press, button: :right} = m, id, _rect, info, ctx) do
    mod = ctx[:right_click_modifier]

    cond do
      info.tracking and m.mods == [] and Map.get(info, :right_click) == :pane ->
        {p, focus(id, ctx) ++ [{:forward, ev}]}

      info.tracking and mod != nil and m.mods == mod ->
        {%{p | strip: mod}, focus(id, ctx) ++ [{:forward, {:mouse, %{m | mods: []}}}]}

      true ->
        {%{p | swallow_up: %{pane: id, local: nil, tracking: false}},
         [{:menu, id, %{x: m.x, y: m.y}}]}
    end
  end

  defp on_pane(p, ev, _m, _id, _rect, _info, _ctx), do: {p, [{:forward, ev}]}

  defp left_press?(m), do: m.kind == :press and m.button == :left

  defp focus(id, ctx), do: if(id == ctx.focused, do: [], else: [{:focus, id}])

  # --- wheel ---

  defp wheel(p, ev, m, id, info, ctx) do
    cond do
      info.tracking ->
        {p, focus(id, ctx) ++ [{:forward, ev}]}

      m.button not in [:wheel_up, :wheel_down] ->
        {p, []}

      info.alt_screen and info.alternate_scroll ->
        key = if m.button == :wheel_up, do: :up, else: :down
        {p, focus(id, ctx) ++ [{:keys, id, [Event.key(key)]}]}

      true ->
        {p, focus(id, ctx) ++ [{:scroll, id, wheel_delta(m, ctx)}]}
    end
  end

  defp wheel_delta(m, ctx),
    do: if(m.button == :wheel_up, do: -ctx.scroll_lines, else: ctx.scroll_lines)

  # --- selection gesture ---

  defp press(p, m, id, info, vx, vy, ctx) do
    row = vy + info.scroll.offset
    press = %{pane: id, x: vx, row: row, at: ctx.now_ms, word: nil, moved: false}
    p = %{p | press: press, selection: nil, autoscroll: nil}

    word =
      if m.mods == [] and double?(p.last_click, id, vx, row, ctx.now_ms),
        do: word(info, vy, vx)

    case word do
      {f, l} ->
        sel = %Selection{pane: id, anchor: {f, row}, head: {l, row}, unit: :word, shown: true}

        {%{p | press: %{press | word: {f, l, row}}, selection: sel, last_click: nil},
         focus(id, ctx)}

      nil ->
        {p, focus(id, ctx)}
    end
  end

  defp double?(%{pane: id, x: x, row: row, at: at}, id, vx, vrow, now),
    do: now - at <= @double_ms and abs(x - vx) <= 1 and abs(row - vrow) <= 1

  defp double?(_last, _id, _x, _row, _now), do: false

  defp gesture(p, ev, %{kind: :scroll} = m, rect, info, ctx) do
    if m.button in [:wheel_up, :wheel_down] do
      delta = wheel_delta(m, ctx)
      off = clamp(info.scroll.offset + delta, 0, max_offset(info.scroll))
      {vx, vy} = clamped(m, rect)
      new = select(p, p.press, {vx, vy + off}, info)
      {new, [{:scroll, p.press.pane, delta}]}
    else
      {p, [{:forward, ev}]}
    end
  end

  defp gesture(p, _ev, %{kind: :drag} = m, rect, info, _ctx) do
    {vx, vy} = clamped(m, rect)
    {off, auto, actions} = autoscroll(p, m.y - rect.y, rect.h, info.scroll)
    {select(%{p | autoscroll: auto}, p.press, {vx, vy + off}, info), actions}
  end

  defp gesture(p, _ev, %{kind: :release}, rect, _info, ctx) do
    press = p.press
    sel = p.selection
    stop = if p.autoscroll, do: [:autoscroll_stop], else: []
    p = %{p | press: nil, autoscroll: nil}

    cond do
      sel == nil or not sel.shown ->
        {%{p | last_click: %{pane: press.pane, x: press.x, row: press.row, at: press.at}}, stop}

      not ctx.copy_on_select ->
        {p, stop}

      true ->
        {from, to} = Selection.range(sel, rect.w)
        copy = [{:copy, press.pane, from, to}]

        if press.word != nil and not press.moved,
          do: {p, stop ++ copy ++ [{:expire_selection, @keep_ms}]},
          else: {%{p | selection: nil}, stop ++ copy}
    end
  end

  defp clamped(m, rect),
    do: {clamp(m.x - rect.x, 0, rect.w - 1), clamp(m.y - rect.y, 0, rect.h - 1)}

  # pointer on the top/bottom row (or beyond: first a jump of clamp(3 * distance, 3, 15))
  defp autoscroll(p, vy, h, scroll) do
    id = p.press.pane
    off = scroll.offset

    {dir, beyond} = edge(vy, h)

    cond do
      dir == nil ->
        {off, nil, if(p.autoscroll, do: [:autoscroll_stop], else: [])}

      p.autoscroll == %{pane: id, dir: dir} ->
        {off, p.autoscroll, []}

      beyond > 0 ->
        jump = clamp(3 * beyond, 3, 15)
        delta = if dir == :up, do: -jump, else: jump
        new_off = clamp(off + delta, 0, max_offset(scroll))
        {new_off, %{pane: id, dir: dir}, [{:scroll, id, delta}, {:autoscroll, id, dir}]}

      true ->
        {off, %{pane: id, dir: dir}, [{:autoscroll, id, dir}]}
    end
  end

  defp edge(vy, _h) when vy <= 0, do: {:up, -vy}
  defp edge(vy, h) when vy >= h - 1, do: {:down, vy - (h - 1)}
  defp edge(_vy, _h), do: {nil, 0}

  # the selection from the press to `head` (absolute); a word press extends by words
  defp select(p, %{word: nil} = press, head, _info) do
    anchor = {press.x, press.row}
    moved = press.moved or head != anchor
    sel = %Selection{pane: press.pane, anchor: anchor, head: head, unit: :char, shown: moved}
    %{p | selection: sel, press: %{press | moved: moved}}
  end

  # `info.rows` are the rows fetched before any scroll this event asked for, at
  # `info.scroll.offset`: absolute row `hrow` is their row `hrow - offset` when inside
  # them, else the head is a plain cell
  defp select(p, %{word: {f, l, arow}} = press, {hx, hrow} = at, info) do
    {hf, hl} = word(info, hrow - info.scroll.offset, hx) || {hx, hx}

    {anchor, head} =
      if {hrow, hx} < {arow, f}, do: {{l, arow}, {hf, hrow}}, else: {{f, arow}, {hl, hrow}}

    moved = press.moved or at != {press.x, press.row}
    sel = %Selection{pane: press.pane, anchor: anchor, head: head, unit: :word, shown: true}
    %{p | selection: sel, press: %{press | moved: moved}}
  end

  defp word(%{rows: rows}, vy, vx) when is_tuple(rows) and vy >= 0 and vy < tuple_size(rows),
    do: rows |> elem(vy) |> Cell.decode_row() |> Words.word_at(vx)

  defp word(_info, _vy, _vx), do: nil

  # --- scrollbar ---

  defp scrollbar?(info, rect, vx),
    do: vx == rect.w - 1 and info.scroll.offset < max_offset(info.scroll)

  defp scrollbar_press(p, id, rect, info, vy, ctx) do
    {len, top} = thumb(info.scroll, rect.h)

    if vy >= top and vy < top + len do
      {%{p | drag: %{kind: :scrollbar, pane: id, grab: vy - top}, press: nil}, focus(id, ctx)}
    else
      top = clamp(vy - div(len, 2), 0, rect.h - len)
      p = %{p | drag: %{kind: :scrollbar, pane: id, grab: vy - top}, press: nil}
      {p, focus(id, ctx) ++ [{:scroll_top, id, offset_at(info.scroll, rect.h, len, top)}]}
    end
  end

  defp scrollbar_drag(p, _ev, %{kind: :release}, _ctx), do: {%{p | drag: nil}, []}

  defp scrollbar_drag(%{drag: %{pane: id, grab: grab}} = p, _ev, m, ctx) do
    case pane(ctx, id) do
      nil ->
        {%{p | drag: nil}, []}

      {rect, info} ->
        {len, _} = thumb(info.scroll, rect.h)
        top = clamp(m.y - rect.y - grab, 0, rect.h - len)
        off = offset_at(info.scroll, rect.h, len, top)
        {p, if(off == info.scroll.offset, do: [], else: [{:scroll_top, id, off}])}
    end
  end

  # herdr scrollbar.rs: length round(viewport * track / total) in [1, track], proportional
  defp thumb(%{total: t, viewport: v} = s, h) do
    len = clamp(round(v * h / max(t, 1)), 1, h)
    max = max_offset(s)
    top = if max > 0, do: round(s.offset * (h - len) / max), else: h - len
    {len, top}
  end

  defp offset_at(s, h, len, top) when h > len, do: round(top * max_offset(s) / (h - len))
  defp offset_at(s, _h, _len, _top), do: s.offset

  defp max_offset(%{total: t, viewport: v}), do: max(t - v, 0)

  # --- links ---

  defp link(%{rows: rows}, rect, vx, vy) when is_tuple(rows), do: Links.at(rows, rect.w, vx, vy)
  defp link(_info, _rect, _vx, _vy), do: nil

  defp target(%{id: 0, url: url}, _x, _y), do: %{url: url}
  defp target(%{id: id}, x, y), do: %{id: id, x: x, y: y}

  # --- helpers ---

  defp hit(ctx, m) do
    Enum.find_value(ctx.panes, fn %{id: id, rect: r} ->
      if m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h, do: {id, r}
    end)
  end

  defp pane(ctx, id) do
    with %{rect: rect} <- Enum.find(ctx.panes, &(&1.id == id)),
         %{} = info <- ctx.info[id],
         do: {rect, info},
         else: (_ -> nil)
  end

  defp repaint(old, new, actions) do
    if {old.selection, old.hover} != {new.selection, new.hover} and :repaint not in actions,
      do: actions ++ [:repaint],
      else: actions
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
