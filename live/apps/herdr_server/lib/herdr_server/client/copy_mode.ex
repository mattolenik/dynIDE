defmodule HerdrServer.Client.CopyMode do
  @moduledoc """
  Pure per-client vi copy mode on one pane (herdr copy_mode.rs), the state behind the
  client input mode `:copy`.

  Positions are `{col, row}` with `row` an absolute screen row (viewport row + scroll
  offset), as in `Client.Selection`. `top` is the viewport top this mode works against
  and `seen` the live offset it last observed: a live offset that differs from `seen`
  (output following the bottom, the wheel, another client) is authoritative, otherwise
  `top` stands (this mode's own `{:scroll_top}` cast may not have landed). `entry` the offset saved
  at entry (`:bottom` when the pane was at the bottom), restored on exit.

  `key/3` takes a context `%{scroll, h, w, read}`: `scroll` is the pane's live
  `%{total, viewport, offset}`, `h`/`w` its size and `read` an `{m, f, a}` called as
  `apply(m, f, a ++ [first, last])`, returning `[{row, packed_row, wrapped}]` for
  inclusive absolute rows (`Native.Vt.screen_rows/3`). It returns `{t, actions}` or
  `{:exit, actions}`; actions are `{:scroll_top, id, row}`, `{:scroll_bottom, id}`,
  `{:copy, id, from, to}` and `{:notice, map}`, executed by `Client.PointerIo.run/3`.

  Keys: `h j k l` and arrows, `C-b C-f` / PageUp PageDown (h - 2 rows), `C-u C-d`
  (h / 2; 1 row when h <= 2), `g G`, `0`/Home, `$`/End, `^`, `w b e W B E` (classes
  whitespace / ASCII separator / word, across soft wraps), `{ }` (nearest blank row,
  at most 1000 rows), `v`/space and `V` (re-anchor a char or line selection), `y`/Enter
  (copy the selection, else the current match, and exit), `q` (exit), Esc (clear the
  selection and search, then exit), `/ ?` (prompt; Enter submits, Esc closes; smart case;
  at most 4096 bytes), `n N`. Searches read rows in windows of 200 from the cursor, at
  most 20_000 rows in total. A search that reaches the end (`/`, `n`) or the top (`?`, `N`)
  without a match wraps once to the other end and notes `search wrapped`; the wrapped leg
  spends what is left of the same 20_000-row budget, so a miss never costs more.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene.Overlay
  alias HerdrServer.App.Keybinds
  alias HerdrServer.Client.{Selection, Words}

  @type pos :: {non_neg_integer, non_neg_integer}
  @type t :: %__MODULE__{
          pane: term,
          cursor: pos,
          entry: non_neg_integer | :bottom,
          top: non_neg_integer,
          seen: non_neg_integer,
          anchor: pos | nil,
          unit: :char | :line,
          prompt: nil | %{dir: :forward | :backward, query: binary},
          search: nil | %{dir: :forward | :backward, query: binary},
          match: nil | {pos, pos},
          matches: [{pos, pos}]
        }

  defstruct pane: nil,
            cursor: {0, 0},
            entry: 0,
            top: 0,
            seen: 0,
            anchor: nil,
            unit: :char,
            prompt: nil,
            search: nil,
            match: nil,
            matches: []

  @separators "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~" |> String.graphemes() |> MapSet.new()
  @query_max 4096
  @search_window 200
  @search_rows 20_000
  @paragraph_rows 1000
  @word_rows 4096
  @word_window 64

  @commands [
              {["h", :left], {:move, -1, 0}},
              {["l", :right], {:move, 1, 0}},
              {["j", :down], {:move, 0, 1}},
              {["k", :up], {:move, 0, -1}},
              {["g"], :top},
              {["G"], :bottom},
              {["0", :home], :bol},
              {["$", :end], :eol},
              {["^"], :first},
              {["{"], {:paragraph, -1}},
              {["}"], {:paragraph, 1}},
              {["v", " "], {:select, :char}},
              {["V"], {:select, :line}},
              {["y", :enter], :yank},
              {["q"], :quit},
              {[:escape], :escape},
              {["/"], {:prompt, :forward}},
              {["?"], {:prompt, :backward}},
              {["n"], {:next, false}},
              {["N"], {:next, true}}
            ]
            |> Enum.flat_map(fn {keys, cmd} -> for k <- keys, do: {{k, []}, cmd} end)
            |> Map.new()
            |> Map.merge(Map.new(~w(w b e W B E), &{{&1, []}, {:word, &1}}))

  @pages %{
    {"b", [:ctrl]} => {-1, :page},
    {:page_up, []} => {-1, :page},
    {"f", [:ctrl]} => {1, :page},
    {:page_down, []} => {1, :page},
    {"u", [:ctrl]} => {-1, :half},
    {"d", [:ctrl]} => {1, :half}
  }

  @doc "Enters copy mode on `pane`; `cursor` is the visible terminal cursor (viewport) or nil."
  @spec enter(term, %{cursor: pos | nil, scroll: map, h: pos_integer, w: pos_integer}) :: t
  def enter(pane, %{cursor: cursor, scroll: scroll, h: h, w: w}) do
    top = scroll.offset
    last = max(scroll.total - 1, 0)

    {x, y} =
      case cursor do
        {x, y} -> {min(x, w - 1), min(top + y, last)}
        nil -> {0, min(top + h - 1, last)}
      end

    entry = if top >= max_top(scroll.total, h), do: :bottom, else: top
    %__MODULE__{pane: pane, cursor: {x, y}, entry: entry, top: top, seen: top}
  end

  @doc "The status label while a search prompt is open (`/query`, `?query`), else nil."
  @spec label(t) :: binary | nil
  def label(%__MODULE__{prompt: %{dir: :forward, query: q}}), do: "/" <> q
  def label(%__MODULE__{prompt: %{dir: :backward, query: q}}), do: "?" <> q
  def label(_t), do: nil

  @doc "The actions that leave copy mode without copying (restore the entry offset)."
  @spec leave(t) :: [tuple]
  def leave(%__MODULE__{pane: id, entry: :bottom}), do: [{:scroll_bottom, id}]
  def leave(%__MODULE__{pane: id, entry: row}), do: [{:scroll_top, id, row}]

  @doc "The selection as a `Client.Selection` (head at the cursor), or nil."
  @spec selection(t) :: Selection.t() | nil
  def selection(%__MODULE__{anchor: nil}), do: nil

  def selection(t),
    do: %Selection{pane: t.pane, anchor: t.anchor, head: t.cursor, unit: t.unit, shown: true}

  @doc """
  Overlays for a `w` x `h` viewport whose top is absolute row `offset`: the selection,
  search matches inside the viewport (`current` for the match the cursor went to) and
  the copy cursor.
  """
  @spec overlays(t, non_neg_integer, non_neg_integer, non_neg_integer) :: [Overlay.t()]
  def overlays(%__MODULE__{} = t, offset, w, h) do
    in_view = fn {_, y} -> y >= offset and y < offset + h end
    rel = fn {x, y} -> {min(x, w - 1), y - offset} end

    matches =
      for {a, b} = m <- t.matches, in_view.(a) and in_view.(b) do
        %Overlay{kind: :search_match, args: %{from: rel.(a), to: rel.(b), current: m == t.match}}
      end

    cursor =
      if in_view.(t.cursor),
        do: [%Overlay{kind: :copy_cursor, args: %{at: rel.(t.cursor)}}],
        else: []

    List.wrap(Selection.overlay(selection(t), %{offset: offset}, w, h)) ++ matches ++ cursor
  end

  @doc "Handles one key event (see moduledoc)."
  @spec key(t, tuple, map) :: {t, [tuple]} | {:exit, [tuple]}
  def key(t, {:key, %{event: :release}}, _ctx), do: {t, []}
  def key(t, ev, ctx), do: keyed(observe(t, ctx.scroll.offset), ev, ctx)

  defp observe(%{seen: live} = t, live), do: t
  defp observe(t, live), do: %{t | top: live, seen: live}

  defp keyed(%__MODULE__{prompt: %{}} = t, {:key, %{key: k, mods: m}}, ctx),
    do: prompt(t, norm(k, m), ctx)

  defp keyed(t, {:key, %{key: k, mods: m}}, ctx) do
    case command(norm(k, m), ctx.h) do
      nil -> {t, []}
      cmd -> t |> run(cmd, ctx) |> refresh(ctx)
    end
  end

  defp norm(k, m) do
    {k, m} = Keybinds.normalize(k, m)
    if is_binary(k), do: {k, m -- [:shift]}, else: {k, m}
  end

  defp command(key, h) do
    case @pages do
      %{^key => {sign, size}} -> {:page, sign * page_rows(size, h)}
      _ -> Map.get(@commands, key)
    end
  end

  defp page_rows(_size, h) when h <= 2, do: 1
  defp page_rows(:page, h), do: h - 2
  defp page_rows(:half, h), do: div(h, 2)

  # --- commands: {t, actions} with t's cursor moved; refresh/2 then scrolls to it ---

  defp run(%{cursor: {x, y}} = t, {:move, dx, dy}, ctx),
    do: {%{t | cursor: {clamp(x + dx, 0, ctx.w - 1), clamp(y + dy, 0, last(ctx))}}, []}

  defp run(%{cursor: {x, y}} = t, {:page, d}, ctx) do
    top = clamp(t.top + d, 0, max_top(ctx.scroll.total, ctx.h))
    {%{t | cursor: {x, clamp(y + d, 0, last(ctx))}}, top: top}
  end

  defp run(%{cursor: {x, _}} = t, :top, _ctx), do: {%{t | cursor: {x, 0}}, []}
  defp run(%{cursor: {x, _}} = t, :bottom, ctx), do: {%{t | cursor: {x, last(ctx)}}, []}
  defp run(%{cursor: {_, y}} = t, :bol, _ctx), do: {%{t | cursor: {0, y}}, []}

  defp run(%{cursor: {_, y}} = t, edge, ctx) when edge in [:eol, :first] do
    cells =
      case read(ctx, y, y) do
        [{_, cells}] -> Words.text_cells(cells)
        _ -> []
      end

    filled = Enum.reject(cells, fn {g, _, _} -> Words.blank?(g) end)
    pick = if edge == :eol, do: List.last(filled), else: List.first(filled)
    {%{t | cursor: {(pick && elem(pick, 1)) || 0, y}}, []}
  end

  defp run(t, {:word, k}, ctx), do: {%{t | cursor: word(t.cursor, k, ctx) || t.cursor}, []}

  defp run(%{cursor: {x, y}} = t, {:paragraph, dir}, ctx),
    do: {%{t | cursor: {x, paragraph(y, dir, ctx)}}, []}

  defp run(t, {:select, unit}, _ctx), do: {%{t | anchor: t.cursor, unit: unit}, []}

  defp run(t, :yank, ctx) do
    copy =
      case {selection(t), t.match} do
        {%Selection{} = sel, _} -> [copy(t.pane, Selection.range(sel, ctx.w))]
        {nil, {a, b}} -> [copy(t.pane, {a, b})]
        _ -> []
      end

    {:exit, copy ++ leave(t)}
  end

  defp run(t, :quit, _ctx), do: {:exit, leave(t)}

  defp run(%{anchor: nil, search: nil, match: nil} = t, :escape, _ctx), do: {:exit, leave(t)}

  defp run(t, :escape, _ctx),
    do: {%{t | anchor: nil, search: nil, match: nil, matches: []}, []}

  defp run(t, {:prompt, dir}, _ctx), do: {%{t | prompt: %{dir: dir, query: ""}}, []}
  defp run(%{search: nil} = t, {:next, _}, _ctx), do: {t, []}

  defp run(%{search: s} = t, {:next, reverse?}, ctx),
    do: find(t, if(reverse?, do: flip(s.dir), else: s.dir), ctx)

  defp copy(id, {a, b}), do: {:copy, id, a, b}
  defp flip(:forward), do: :backward
  defp flip(:backward), do: :forward

  # keeps the cursor inside the viewport (scrolling as little as possible) and refreshes
  # the visible search matches
  defp refresh({:exit, _} = exit, _ctx), do: exit

  defp refresh({t, actions}, ctx) do
    {top, actions} = Keyword.pop(actions, :top, t.top)
    {_, y} = t.cursor

    top =
      cond do
        y < top -> y
        y > top + ctx.h - 1 -> y - ctx.h + 1
        true -> top
      end
      |> clamp(0, max_top(ctx.scroll.total, ctx.h))

    scroll = if top == t.top, do: [], else: [{:scroll_top, t.pane, top}]
    t = %{t | top: top}
    {%{t | matches: visible_matches(t, ctx)}, scroll ++ actions}
  end

  # --- the search prompt ---

  defp prompt(t, {:enter, []}, ctx) do
    case t.prompt do
      %{query: ""} ->
        {%{t | prompt: nil}, []}

      %{} = p ->
        t = %{t | prompt: nil, search: p}
        t |> find(p.dir, ctx) |> refresh(ctx)
    end
  end

  defp prompt(t, {:escape, []}, _ctx), do: {%{t | prompt: nil}, []}

  defp prompt(%{prompt: p} = t, {:backspace, []}, _ctx),
    do: {%{t | prompt: %{p | query: drop_last(p.query)}}, []}

  defp prompt(%{prompt: p} = t, {g, []}, _ctx) when is_binary(g) do
    if byte_size(p.query) + byte_size(g) > @query_max,
      do: {t, []},
      else: {%{t | prompt: %{p | query: p.query <> g}}, []}
  end

  defp prompt(t, _key, _ctx), do: {t, []}

  defp drop_last(q), do: q |> String.graphemes() |> Enum.drop(-1) |> Enum.join()

  # --- search ---

  defp find(%{search: %{query: q}, cursor: {x, y}} = t, dir, ctx) do
    case search(q, {x, y}, dir, ctx) do
      {{a, _} = m, wrapped?} ->
        notice = if wrapped?, do: [{:notice, %{level: :info, text: "search wrapped"}}], else: []
        {%{t | cursor: a, match: m}, notice}

      nil ->
        {%{t | match: nil}, [{:notice, %{level: :info, text: "no match for " <> q}}]}
    end
  end

  # First leg from the cursor; if it ran into the buffer end within budget, one wrapped leg
  # from the other end over the remaining budget (cursor row included). Returns {match, wrapped?}.
  defp search(q, {x, y}, :forward, ctx) do
    last = last(ctx)

    case scan(q, y, min(y + @search_rows - 1, last), 1, ctx, fn r, mx -> r > y or mx > x end) do
      nil when y + @search_rows - 1 >= last ->
        left = @search_rows - (last - y + 1)
        wrap(scan(q, 0, min(y, left - 1), 1, ctx, fn _, _ -> true end))

      m ->
        m && {m, false}
    end
  end

  defp search(q, {x, y}, :backward, ctx) do
    last = last(ctx)

    case scan(q, y, max(y - @search_rows + 1, 0), -1, ctx, fn r, mx -> r < y or mx < x end) do
      nil when y - @search_rows + 1 <= 0 ->
        left = @search_rows - (y + 1)
        wrap(scan(q, last, max(y, last - left + 1), -1, ctx, fn _, _ -> true end))

      m ->
        m && {m, false}
    end
  end

  defp wrap(nil), do: nil
  defp wrap(m), do: {m, true}

  # first match (in `dir` order) over rows from..to accepted by `ok?.(row, match_x)`
  defp scan(q, from, to, 1, ctx, ok?) do
    from
    |> windows(to, 1, @search_window)
    |> Stream.flat_map(fn {first, l} -> read(ctx, first, l) end)
    |> Enum.find_value(fn {r, cells} ->
      Enum.find(row_matches(cells, r, q), fn {{mx, _}, _} -> ok?.(r, mx) end)
    end)
  end

  defp scan(q, from, to, -1, ctx, ok?) do
    from
    |> windows(to, -1, @search_window)
    |> Stream.flat_map(fn {first, l} -> ctx |> read(first, l) |> Enum.reverse() end)
    |> Enum.find_value(fn {r, cells} ->
      cells
      |> row_matches(r, q)
      |> Enum.reverse()
      |> Enum.find(fn {{mx, _}, _} -> ok?.(r, mx) end)
    end)
  end

  # inclusive row windows of `n` rows from `from` towards `to`, in reading order
  defp windows(from, to, 1, n) when from <= to,
    do: for(s <- from..to//n, do: {s, min(s + n - 1, to)})

  defp windows(from, to, -1, n) when from >= to,
    do: for(e <- from..to//-n, do: {max(e - n + 1, to), e})

  defp windows(_, _, _, _), do: []

  defp visible_matches(%{search: nil}, _ctx), do: []

  defp visible_matches(%{search: %{query: q}, top: top}, ctx) do
    for {r, cells} <- read(ctx, top, min(top + ctx.h - 1, last(ctx))),
        m <- row_matches(cells, r, q),
        do: m
  end

  # non-overlapping matches of `q` on one row, as {{x1, r}, {x2, r}} (smart case)
  defp row_matches(cells, r, q) do
    fold = if String.downcase(q) == q, do: &String.downcase/1, else: & &1
    tc = cells |> Words.text_cells() |> List.to_tuple()

    {bin, starts, ends, _} =
      Enum.reduce(0..(tuple_size(tc) - 1)//1, {[], %{}, %{}, 0}, fn i, {bin, s, e, off} ->
        g = tc |> elem(i) |> elem(0) |> then(&if(&1 == "", do: " ", else: fold.(&1)))
        stop = off + byte_size(g)
        {[bin, g], Map.put(s, off, i), Map.put(e, stop, i), stop}
      end)

    for {pos, len} <- :binary.matches(IO.iodata_to_binary(bin), fold.(q)),
        si = starts[pos],
        ei = ends[pos + len],
        si != nil and ei != nil,
        do: {{elem(elem(tc, si), 1), r}, {elem(elem(tc, ei), 2), r}}
  end

  # --- word motions: a lazy stream of {x | nil, row, class} from the cursor ---

  defp word({x, y}, k, ctx) do
    big? = k in ~w(W B E)
    dir = if k in ~w(b B), do: -1, else: 1
    stream = cells(ctx, {x, y}, dir, big?)

    case String.downcase(k) do
      "w" ->
        next_word(stream, Enum.take(stream, 1))

      _end_or_back ->
        stream |> Stream.drop(1) |> Stream.drop_while(&space?/1) |> run_end()
    end
  end

  defp space?({_, _, c}), do: c == :space

  # past the cursor's run (unless on space), then past spaces
  defp next_word(_stream, []), do: nil

  defp next_word(stream, [{_, _, c0}]),
    do: stream |> Stream.drop_while(fn {_, _, c} -> c == c0 and c != :space end) |> first_word()

  defp first_word(stream) do
    case stream |> Stream.drop_while(&space?/1) |> Enum.take(1) do
      [{x, y, _}] -> {x, y}
      [] -> nil
    end
  end

  # the last item of the first run of one class
  defp run_end(stream) do
    case Enum.take(stream, 1) do
      [{_, _, c}] ->
        {x, y, _} =
          stream
          |> Stream.take_while(fn {_, _, c2} -> c2 == c end)
          |> Enum.reduce(fn i, _ -> i end)

        {x, y}

      [] ->
        nil
    end
  end

  defp cells(ctx, {x, y}, dir, big?) do
    stop = if dir == 1, do: min(y + @word_rows - 1, last(ctx)), else: max(y - @word_rows + 1, 0)

    y
    |> windows(stop, dir, @word_window)
    |> Stream.flat_map(fn {first, l} ->
      rows = call(ctx.read, first, l)
      if dir == 1, do: rows, else: Enum.reverse(rows)
    end)
    |> Stream.flat_map(&row_items(&1, {x, y}, dir, big?))
  end

  # a row's text cells as {x, row, class} in reading order; on the cursor row only those
  # from the cursor on. A hard line end is a space; a soft wrap joins the rows.
  defp row_items({r, packed, wrapped}, {x, y}, dir, big?) do
    items =
      for {g, x1, x2} <- packed |> Cell.decode_row() |> Words.text_cells(),
          from_cursor?(r, x1, x2, {x, y}, dir),
          do: {x1, r, class(g, big?)}

    items = if wrapped or (r == y and dir == -1), do: items, else: items ++ [{nil, r, :space}]
    if dir == 1, do: items, else: Enum.reverse(items)
  end

  defp from_cursor?(r, _x1, _x2, {_x, y}, _dir) when r != y, do: true
  defp from_cursor?(_r, _x1, x2, {x, _y}, 1), do: x2 >= x
  defp from_cursor?(_r, x1, _x2, {x, _y}, -1), do: x1 <= x

  defp class(g, big?) do
    cond do
      Words.blank?(g) -> :space
      not big? and MapSet.member?(@separators, g) -> :sep
      true -> :word
    end
  end

  # --- paragraphs ---

  defp paragraph(y, 1, ctx),
    do: blank_row(ctx, {y + 1, min(y + @paragraph_rows, last(ctx))}, 1, last(ctx), y)

  defp paragraph(y, -1, ctx),
    do: blank_row(ctx, {y - 1, max(y - @paragraph_rows, 0)}, -1, 0, y)

  # the first blank row from `from` towards `to` (read in windows, like search), else
  # `edge` when the range reaches it, else `y`
  defp blank_row(ctx, {from, to}, dir, edge, y) do
    order = if dir == 1, do: & &1, else: &Enum.reverse/1

    found =
      from
      |> windows(to, dir, @search_window)
      |> Stream.flat_map(fn {first, l} -> ctx |> read(first, l) |> order.() end)
      |> Enum.find_value(fn {r, cells} -> if Enum.all?(cells, &Words.blank?(&1.glyph)), do: r end)

    cond do
      found -> found
      dir * (to - from) >= 0 and edge == to -> edge
      true -> y
    end
  end

  # --- reading ---

  defp read(ctx, first, l),
    do: for({r, packed, _} <- call(ctx.read, first, l), do: {r, Cell.decode_row(packed)})

  defp call({m, f, a}, first, l), do: apply(m, f, a ++ [first, l])

  defp last(ctx), do: max(ctx.scroll.total - 1, 0)
  defp max_top(total, h), do: max(total - h, 0)
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
