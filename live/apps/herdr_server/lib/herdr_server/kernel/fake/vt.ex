defmodule HerdrServer.Kernel.Fake.Vt do
  @moduledoc """
  Fake terminal: a GenServer holding a grid of glyphs and a small byte
  interpreter (printable UTF-8, CR, LF, BS, HT, `ESC [ 2 J`, `ESC [ r;c H`;
  other escapes ignored; no styles, every glyph one column wide). Rows are
  packed only when read, so a flood costs only the cells it touches.

  Screen lines are `history` (test hook `set_history/2`, oldest first) followed
  by the grid; `offset` is the screen line at the viewport top (nil = bottom).
  With no history it behaves as a plain grid: offset 0, total = viewport = rows.
  """
  use GenServer

  @behaviour HerdrServer.Kernel.Vt

  import Bitwise

  alias HerdrScene.Cell

  defstruct cols: 1,
            rows: 1,
            grid: {},
            cx: 0,
            cy: 0,
            dirty: MapSet.new(),
            gen: 0,
            modes: %{},
            kitty: 0,
            shape: :block,
            blinking: false,
            history: [],
            offset: nil,
            colors: nil,
            scheme: nil,
            fail_scroll: false,
            links: %{},
            graphics: [],
            images: %{}

  @impl HerdrServer.Kernel.Vt
  def new(cols, rows, _max_scrollback), do: GenServer.start_link(__MODULE__, {cols, rows})

  @doc "Test hook: feed bytes; `gen` (the pty's damage generation) defaults to gen + 1."
  def write(vt, bin, gen \\ nil), do: GenServer.cast(vt, {:write, bin, gen})

  @doc "Test hook: like `write/2`, but returns once the bytes are applied."
  def write_sync(vt, bin), do: GenServer.call(vt, {:write_sync, bin})

  @doc "Makes the next `dirty_rows/1` return every row."
  def force_full(vt), do: GenServer.cast(vt, :force_full)

  @doc "Test hook: `mode` is an M1 mode atom (e.g. `:bracketed_paste`)."
  def set_mode(vt, mode, on?), do: GenServer.call(vt, {:set_mode, mode, on?})

  @doc "Test hook: the cursor shape (M1's shapes) and blinking `cursor/1` reports."
  def set_cursor_shape(vt, shape, blinking \\ false),
    do: GenServer.call(vt, {:shape, shape, blinking})

  @doc "Test hook."
  def set_kitty_flags(vt, n), do: GenServer.call(vt, {:kitty, n})

  @doc "Test hook: appends `lines` (text) to the scrollback above the grid."
  def set_history(vt, lines), do: GenServer.call(vt, {:history, lines})

  @doc "Test hook: the last `set_colors/2` map (nil before any) and `set_color_scheme/2` value."
  def colors(vt), do: GenServer.call(vt, :colors)

  @impl HerdrServer.Kernel.Vt
  # like the NIF: a malformed map raises
  def set_colors(vt, colors) do
    unless is_map(colors) and Enum.all?(colors, &colour?/1),
      do: raise(ArgumentError, "malformed colours: #{inspect(colors)}")

    GenServer.call(vt, {:colors, colors})
  end

  defp colour?({k, v}) when k in [:fg, :bg, :cursor], do: v == nil or rgb?(v)

  defp colour?({:palette, p}) when is_map(p),
    do: Enum.all?(p, fn {i, v} -> i in 0..255 and rgb?(v) end)

  defp colour?(_), do: false

  defp rgb?({r, g, b}), do: Enum.all?([r, g, b], &(&1 in 0..255))
  defp rgb?(_), do: false

  @doc "Test hook: the next `scroll_to/2` raises `ErlangError` (as a ghostty error does)."
  def fail_next_scroll(vt), do: GenServer.call(vt, :fail_scroll)

  @impl HerdrServer.Kernel.Vt
  def set_color_scheme(vt, scheme), do: GenServer.call(vt, {:scheme, scheme})

  @impl HerdrServer.Kernel.Vt
  def modify_other_keys(_vt), do: false

  @impl HerdrServer.Kernel.Vt
  def screen_rows(vt, first, last) when first >= 0 and last >= 0,
    do: GenServer.call(vt, {:screen_rows, first, last})

  @impl HerdrServer.Kernel.Vt
  def search(vt, query, %{from: from, direction: dir} = opts) do
    from = if dir == :backward, do: min(from, max(scrollbar(vt).total - 1, 0)), else: from
    search_with({__MODULE__, :screen_rows, [vt]}, query, %{opts | from: from})
  end

  @doc """
  `Native.Vt.search/3`'s contract over a `screen_rows/3`-shaped reader `{m, f, a}`
  (called as `apply(m, f, a ++ [first, last])`), in Elixir: the fake's search, and the
  reference matcher for tests. Going backward, `from` must be a row that exists.
  """
  def search_with(_read, "", _opts), do: {:ok, [], :done}

  def search_with(read, query, opts) do
    fold = if opts.case_sensitive, do: & &1, else: &String.downcase/1
    dir = if opts.direction == :forward, do: 1, else: -1
    scan(read, {fold.(query), fold}, opts.from, opts.max_rows, dir, opts.max_matches, [])
  end

  @window 200

  defp scan(read, q, row, left, dir, max, acc) do
    n = min(left, @window)
    {a, b} = if dir == 1, do: {row, row + n - 1}, else: {max(row - n + 1, 0), row}
    rows = for {r, packed, _} <- read_rows(read, a, b), do: {r, packed}
    rows = if dir == 1, do: rows, else: Enum.reverse(rows)

    case scan_rows(rows, q, left, dir, max, acc, dir == 1 and length(rows) < n) do
      {:stop, acc, next} -> {:ok, Enum.reverse(acc), past_end(read, next)}
      {:more, acc, left} -> scan(read, q, row + dir * n, left, dir, max, acc)
    end
  end

  # like the kernel: :done when the row after the stop row does not exist
  defp past_end(read, next) when is_integer(next),
    do: if(read_rows(read, next, next) == [], do: :done, else: next)

  defp past_end(_read, next), do: next

  defp read_rows({m, f, args}, a, b), do: apply(m, f, args ++ [a, b])

  defp scan_rows([], _q, left, _dir, _max, acc, false), do: {:more, acc, left}
  defp scan_rows([], _q, _left, _dir, _max, acc, true), do: {:stop, acc, :done}

  defp scan_rows([{r, packed} | rest], q, left, dir, max, acc, short?) do
    acc = Enum.reverse(row_matches(packed, r, q), acc)
    next = r + dir

    cond do
      next < 0 or (rest == [] and short?) -> {:stop, acc, :done}
      left == 1 or length(acc) >= max -> {:stop, acc, next}
      true -> scan_rows(rest, q, left - 1, dir, max, acc, short?)
    end
  end

  # non-overlapping matches on one row's glyphs (wide tails skipped, empty reads as a
  # space) that start and end on glyph boundaries, as {row, col, len}
  defp row_matches(packed, r, {q, fold}) do
    tc =
      for {c, x} <- packed |> Cell.decode_row() |> Enum.with_index(), c.width != 0 do
        {if(c.glyph == "", do: " ", else: fold.(c.glyph)), x, x + max(c.width, 1) - 1}
      end

    {bin, starts, ends, _} =
      Enum.reduce(tc, {[], %{}, %{}, 0}, fn {g, x1, x2}, {bin, s, e, off} ->
        stop = off + byte_size(g)
        {[bin, g], Map.put(s, off, x1), Map.put(e, stop, x2), stop}
      end)

    for {pos, len} <- :binary.matches(IO.iodata_to_binary(bin), q),
        x1 = starts[pos],
        x2 = ends[pos + len],
        x1 != nil and x2 != nil,
        do: {r, x1, x2 - x1 + 1}
  end

  @impl HerdrServer.Kernel.Vt
  def resize(vt, cols, rows, _cell_px), do: GenServer.call(vt, {:resize, cols, rows})

  @impl HerdrServer.Kernel.Vt
  def dirty_rows(vt), do: GenServer.call(vt, :dirty_rows)

  @impl HerdrServer.Kernel.Vt
  def full_rows(vt), do: GenServer.call(vt, :full_rows)

  @impl HerdrServer.Kernel.Vt
  def read_text(vt, {:selection, {x1, y1}, {x2, y2}} = what)
      when x1 >= 0 and y1 >= 0 and x2 >= 0 and y2 >= 0,
      do: GenServer.call(vt, {:read_text, what})

  def read_text(vt, what) when what in [:viewport, :screen] or elem(what, 0) == :rows,
    do: GenServer.call(vt, {:read_text, what})

  @impl HerdrServer.Kernel.Vt
  def tail_ansi(vt, n) when is_integer(n) and n >= 0, do: GenServer.call(vt, {:tail, n})

  @impl HerdrServer.Kernel.Vt
  def scrollbar(vt), do: GenServer.call(vt, :scrollbar)

  @impl HerdrServer.Kernel.Vt
  def size(vt), do: GenServer.call(vt, :size)

  @impl HerdrServer.Kernel.Vt
  def scroll_to(vt, offset) do
    with :raise <- GenServer.call(vt, {:scroll_to, offset}),
         do: :erlang.error({:ghostty, :scroll_to})
  end

  @impl HerdrServer.Kernel.Vt
  def mode(vt, id), do: GenServer.call(vt, {:mode, id})

  @impl HerdrServer.Kernel.Vt
  def kitty_keyboard_flags(vt), do: GenServer.call(vt, :kitty)

  @doc """
  Test hook: OSC 8 link `id` on the viewport cells `cells` (`[{x, y}]`), packed into
  their rows from the next read on; `link_at/3` there answers `uri` (nil: no link,
  as a stale id would).
  """
  def set_link(vt, cells, id, uri), do: GenServer.call(vt, {:set_link, cells, id, uri})

  @impl HerdrServer.Kernel.Vt
  def link_at(vt, x, y), do: GenServer.call(vt, {:link_at, x, y})

  @doc """
  Test hook: `graphics_placements/1` answers `placements` and `graphics_image/2` looks
  ids up in `images` (`%{image_id => payload}`).
  """
  def set_graphics(vt, placements, images \\ %{}),
    do: GenServer.call(vt, {:set_graphics, placements, images})

  @impl HerdrServer.Kernel.Vt
  def graphics_placements(vt), do: GenServer.call(vt, :graphics)

  @impl HerdrServer.Kernel.Vt
  def graphics_image(vt, image_id), do: GenServer.call(vt, {:graphics_image, image_id})

  @impl HerdrServer.Kernel.Vt
  def cursor(vt), do: GenServer.call(vt, :cursor)

  @impl HerdrServer.Kernel.Vt
  def encode_key(vt, %{event: :press} = k), do: key_bytes(k, kitty_keyboard_flags(vt))
  def encode_key(_vt, %{event: _}), do: ""

  @tracking [:mouse_x10, :mouse_normal, :mouse_button, :mouse_any]

  @impl HerdrServer.Kernel.Vt
  def encode_mouse(vt, m) do
    if Enum.any?(@tracking, &mode(vt, &1)) do
      {b, final} = mouse_code(m)
      "\e[<#{b};#{m.x + 1};#{m.y + 1}#{final}"
    end
  end

  @impl HerdrServer.Kernel.Vt
  def encode_focus(vt, focused?) do
    cond do
      not mode(vt, :focus_events) -> ""
      focused? -> "\e[I"
      true -> "\e[O"
    end
  end

  # -- server ---------------------------------------------------------------

  @impl GenServer
  def init({cols, rows}) do
    {:ok, %__MODULE__{cols: cols, rows: rows, grid: blank_grid(cols, rows)}}
  end

  @impl GenServer
  def handle_cast({:write, bin, gen}, state) do
    state = Map.merge(%__MODULE__{}, state)
    max = state.rows * state.cols * 4
    # ponytail: tail may start mid-sequence; fine for a fake, a real vt is the truth
    bin =
      if byte_size(bin) > max,
        do: bin |> binary_part(byte_size(bin) - max, max) |> trim(),
        else: bin

    state = feed(state, bin)
    {:noreply, %{state | gen: gen || state.gen + 1}}
  end

  def handle_cast(:force_full, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | dirty: all_rows(state)}}
  end

  @impl GenServer
  def handle_call(:dirty_rows, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    rows = state.dirty |> Enum.sort() |> Enum.map(&{&1, pack(state, &1)})
    {:reply, {state.gen, rows}, %{state | dirty: MapSet.new()}}
  end

  def handle_call(:full_rows, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {state.gen, Enum.map(0..(state.rows - 1), &{&1, pack(state, &1)})}, state}
  end

  def handle_call({:read_text, {:selection, a, b}}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, selection_text(state, a, b), state}
  end

  def handle_call({:read_text, what}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    range =
      case what do
        {:rows, r} -> r
        :screen -> 0..(total(state) - 1)
        :viewport -> offset(state)..(offset(state) + state.rows - 1)
      end

    text = Enum.map_join(range, "\n", &(state |> text_row(&1) |> String.trim_trailing()))
    {:reply, text, state}
  end

  def handle_call({:write_sync, bin}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state} = handle_cast({:write, bin, nil}, state)
    {:reply, :ok, state}
  end

  def handle_call({:tail, n}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    reply =
      if Map.get(state.modes, :alt_screen, false) do
        :alt_screen
      else
        0..(state.rows - 1)
        |> Enum.map(&(state |> text_row(&1) |> String.trim_trailing()))
        |> Enum.reverse()
        |> Enum.drop_while(&(&1 == ""))
        |> Enum.take(n)
        |> Enum.reverse()
        |> Enum.join("\r\n")
      end

    {:reply, reply, state}
  end

  def handle_call({:screen_rows, first, last}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    last = Enum.min([last, first + 999, total(state) - 1])

    rows =
      if first > last, do: [], else: Enum.map(first..last, &{&1, pack_line(state, &1), false})

    {:reply, rows, state}
  end

  def handle_call(:size, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, {state.cols, state.rows}, state}
  end

  def handle_call(:scrollbar, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, %{total: total(state), viewport: state.rows, offset: offset(state)}, state}
  end

  def handle_call({:scroll_to, _n}, _from, %{fail_scroll: true} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :raise, %{state | fail_scroll: false}}
  end

  def handle_call({:scroll_to, n}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    h = length(state.history)
    new = if min(n, h) == h, do: nil, else: n

    if new == state.offset,
      do: {:reply, :ok, state},
      else: {:reply, :ok, %{state | offset: new, dirty: all_rows(state), gen: state.gen + 1}}
  end

  def handle_call({:set_link, cells, id, uri}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    links = Enum.reduce(cells, state.links, &Map.put(&2, &1, {id, uri}))
    {:reply, :ok, %{state | links: links}}
  end

  def handle_call({:link_at, x, y}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    case state.links do
      %{{^x, ^y} => {_id, uri}} when is_binary(uri) ->
        {:reply, %{uri: uri, kind: :hyperlink}, state}

      _ ->
        {:reply, nil, state}
    end
  end

  def handle_call({:set_graphics, placements, images}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | graphics: placements, images: images}}
  end

  def handle_call(:graphics, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.graphics, state}
  end

  def handle_call({:graphics_image, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Map.get(state.images, id), state}
  end

  def handle_call(:fail_scroll, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | fail_scroll: true}}
  end

  def handle_call({:history, lines}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | history: state.history ++ lines}}
  end

  def handle_call({:colors, colors}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | colors: colors}}
  end

  def handle_call({:scheme, scheme}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | scheme: scheme}}
  end

  def handle_call(:colors, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, %{colors: state.colors, scheme: state.scheme}, state}
  end

  def handle_call({:mode, id}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Map.get(state.modes, id, false), state}
  end

  def handle_call({:set_mode, id, on?}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | modes: Map.put(state.modes, id, on?)}}
  end

  def handle_call({:kitty, n}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | kitty: n}}
  end

  def handle_call(:kitty, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.kitty, state}
  end

  def handle_call({:shape, shape, blinking}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | shape: shape, blinking: blinking}}
  end

  def handle_call(:cursor, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    {:reply,
     %{x: state.cx, y: state.cy, shape: state.shape, visible: true, blinking: state.blinking},
     state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    grid = resized_grid(state, cols, rows)

    state = %{
      state
      | cols: cols,
        rows: rows,
        grid: grid,
        cx: min(state.cx, cols - 1),
        cy: min(state.cy, rows - 1),
        # like ghostty may: a resize snaps the viewport to the bottom
        offset: nil
    }

    {:reply, :ok, %{state | dirty: all_rows(state)}}
  end

  # -- grid -----------------------------------------------------------------

  defp resized_grid(state, cols, rows) do
    old = Tuple.to_list(state.grid)
    fit = fn row, n -> row |> Tuple.to_list() |> Enum.take(n) |> pad(n) end

    for(y <- 0..(rows - 1), do: fit.(Enum.at(old, y, {}), cols) |> List.to_tuple())
    |> List.to_tuple()
  end

  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))

  defp blank_grid(cols, rows), do: Tuple.duplicate(Tuple.duplicate("", cols), rows)
  defp all_rows(state), do: MapSet.new(0..(state.rows - 1))

  # -- screen lines (history ++ grid) ----------------------------------------

  defp total(state), do: length(state.history) + state.rows
  defp offset(state), do: state.offset || length(state.history)

  # viewport row y
  defp pack(%{links: links} = state, y) when map_size(links) > 0 do
    state
    |> line(offset(state) + y)
    |> Enum.with_index(fn g, x -> %Cell{glyph: g, link: link_id(links, x, y)} end)
    |> Cell.encode_row()
  end

  defp pack(state, y), do: pack_line(state, offset(state) + y)

  defp link_id(links, x, y) do
    case links do
      %{{^x, ^y} => {id, _}} -> id
      _ -> 0
    end
  end

  defp pack_line(state, sy),
    do: state |> line(sy) |> Enum.map(&%Cell{glyph: &1}) |> Cell.encode_row()

  # glyphs of screen line sy, cols wide ("" = blank)
  defp line(state, sy) do
    h = length(state.history)

    cond do
      sy < h -> state.history |> Enum.at(sy) |> String.graphemes() |> fit(state.cols)
      sy < h + state.rows -> state.grid |> elem(sy - h) |> Tuple.to_list()
      true -> List.duplicate("", state.cols)
    end
  end

  defp fit(list, n), do: list |> Enum.take(n) |> pad(n)

  defp text_row(state, y) when y >= 0,
    do: state |> line(y) |> Enum.map_join(&if(&1 == "", do: " ", else: &1))

  defp text_row(_state, _y), do: ""

  defp selection_text(state, {x1, y1}, {x2, y2}) do
    clamp = fn {x, y} -> {min(x, state.cols - 1), min(y, total(state) - 1)} end

    [{sx, sy}, {ex, ey}] =
      Enum.sort_by([clamp.({x1, y1}), clamp.({x2, y2})], fn {x, y} -> {y, x} end)

    Enum.map_join(sy..ey, "\n", fn y ->
      from = if y == sy, do: sx, else: 0
      to = if y == ey, do: ex, else: state.cols - 1
      text = text_row(state, y)
      text |> String.slice(from..to//1) |> String.trim_trailing()
    end)
    |> String.trim_trailing()
  end

  # drop continuation bytes left at the front by a mid-character cut
  defp trim(<<b, rest::binary>>) when b >>> 6 == 0b10, do: trim(rest)
  defp trim(bin), do: bin

  # -- byte interpreter -----------------------------------------------------

  defp feed(s, <<>>), do: s
  defp feed(s, <<?\r, r::binary>>), do: feed(%{s | cx: 0}, r)
  defp feed(s, <<?\n, r::binary>>), do: feed(linefeed(s), r)
  defp feed(s, <<?\b, r::binary>>), do: feed(%{s | cx: max(s.cx - 1, 0)}, r)
  defp feed(s, <<?\t, r::binary>>), do: feed(%{s | cx: min(div(s.cx, 8) * 8 + 8, s.cols - 1)}, r)
  defp feed(s, <<?\e, ?[, r::binary>>), do: csi(s, r, "")
  defp feed(s, <<?\e, _, r::binary>>), do: feed(s, r)

  defp feed(s, <<c::utf8, r::binary>>) when c >= 0x20 and c not in 0x7F..0x9F,
    do: feed(put(s, <<c::utf8>>), r)

  defp feed(s, <<_, r::binary>>), do: feed(s, r)

  # parameter/intermediate bytes accumulate; the final byte (0x40..0x7E) decides
  defp csi(s, <<b, r::binary>>, acc) when b in 0x20..0x3F, do: csi(s, r, acc <> <<b>>)
  defp csi(s, <<f, r::binary>>, acc) when f in [?H, ?f], do: feed(home(s, acc), r)

  defp csi(s, <<?J, r::binary>>, "2"),
    do: feed(%{s | grid: blank_grid(s.cols, s.rows), dirty: all_rows(s)}, r)

  defp csi(s, <<f, r::binary>>, _acc) when f in 0x40..0x7E, do: feed(s, r)
  defp csi(s, _rest, _acc), do: s

  defp home(s, acc) do
    [r, c] = (String.split(acc, ";") ++ ["", ""]) |> Enum.take(2) |> Enum.map(&param/1)
    %{s | cy: min(r - 1, s.rows - 1), cx: min(c - 1, s.cols - 1)}
  end

  defp param(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp linefeed(%{cy: cy, rows: rows} = s) when cy == rows - 1 do
    grid =
      s.grid
      |> Tuple.delete_at(0)
      |> then(&Tuple.insert_at(&1, s.rows - 1, Tuple.duplicate("", s.cols)))

    %{s | grid: grid, dirty: all_rows(s)}
  end

  defp linefeed(s), do: %{s | cy: s.cy + 1}

  defp put(%{cx: cx, cols: cols} = s, g) when cx >= cols, do: put(linefeed(%{s | cx: 0}), g)

  defp put(s, g) do
    row = s.grid |> elem(s.cy) |> put_elem(s.cx, g)
    %{s | grid: put_elem(s.grid, s.cy, row), dirty: MapSet.put(s.dirty, s.cy), cx: s.cx + 1}
  end

  # -- key / mouse encoding -------------------------------------------------

  @mod_bits [
    shift: 1,
    alt: 2,
    ctrl: 4,
    super: 8,
    hyper: 16,
    meta: 32,
    caps_lock: 64,
    num_lock: 128
  ]
  @csi_keys %{
    up: "A",
    down: "B",
    right: "C",
    left: "D",
    home: "H",
    end: "F",
    f1: "P",
    f2: "Q",
    f3: "R",
    f4: "S"
  }
  @tilde_keys %{
    insert: 2,
    delete: 3,
    page_up: 5,
    page_down: 6,
    f5: 15,
    f6: 17,
    f7: 18,
    f8: 19,
    f9: 20,
    f10: 21,
    f11: 23,
    f12: 24
  }
  @simple %{enter: {"\r", 13}, tab: {"\t", 9}, backspace: {"\x7f", 127}, escape: {"\e", 27}}

  defp mod_param(mods), do: 1 + Enum.reduce(mods, 0, &(&2 ||| Keyword.get(@mod_bits, &1, 0)))

  defp key_bytes(%{key: key, mods: mods}, kitty) when is_atom(key) do
    p = mod_param(mods)

    cond do
      Map.has_key?(@simple, key) ->
        {legacy, cp} = @simple[key]
        simple_key(legacy, cp, mods, p, kitty)

      Map.has_key?(@csi_keys, key) ->
        if mods == [], do: csi_final(key), else: "\e[1;#{p}#{@csi_keys[key]}"

      Map.has_key?(@tilde_keys, key) ->
        if mods == [], do: "\e[#{@tilde_keys[key]}~", else: "\e[#{@tilde_keys[key]};#{p}~"
    end
  end

  defp key_bytes(%{key: <<c::utf8>> = text, mods: mods}, kitty) do
    p = mod_param(mods)
    lower = String.downcase(text)
    <<cp::utf8>> = lower

    cond do
      mods == [] or mods == [:shift] -> text
      kitty != 0 -> "\e[#{cp};#{p}u"
      :ctrl in mods and cp in ?a..?z -> alt_prefix(mods, <<cp - ?a + 1>>)
      true -> alt_prefix(mods, <<c::utf8>>)
    end
  end

  defp key_bytes(%{key: text}, _kitty), do: text

  defp csi_final(key) when key in [:f1, :f2, :f3, :f4], do: "\eO" <> @csi_keys[key]
  defp csi_final(key), do: "\e[" <> @csi_keys[key]

  defp simple_key(legacy, _cp, [], _p, _kitty), do: legacy
  defp simple_key(_legacy, cp, _mods, p, kitty) when kitty != 0, do: "\e[#{cp};#{p}u"
  defp simple_key(legacy, _cp, mods, _p, _kitty), do: alt_prefix(mods, legacy)

  defp alt_prefix(mods, bytes), do: if(:alt in mods, do: "\e" <> bytes, else: bytes)

  @buttons %{
    left: 0,
    middle: 1,
    right: 2,
    wheel_up: 64,
    wheel_down: 65,
    wheel_left: 66,
    wheel_right: 67
  }

  defp mouse_code(m) do
    mods = Enum.sum(for {mod, bit} <- [shift: 4, alt: 8, ctrl: 16], mod in m.mods, do: bit)
    motion = if m.kind in [:move, :drag], do: 32, else: 0
    {Map.get(@buttons, m.button, 3) + mods + motion, if(m.kind == :release, do: "m", else: "M")}
  end
end
