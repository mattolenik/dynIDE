defmodule HerdrServer.Kernel.Fake.Vt do
  @moduledoc """
  Fake terminal: a GenServer holding a grid of glyphs and a small byte
  interpreter (printable UTF-8, CR, LF, BS, HT, `ESC [ 2 J`, `ESC [ r;c H`;
  other escapes ignored; no styles, every glyph one column wide). Rows are
  packed only when read, so a flood costs only the cells it touches.
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
            kitty: 0

  @impl HerdrServer.Kernel.Vt
  def new(cols, rows, _max_scrollback), do: GenServer.start_link(__MODULE__, {cols, rows})

  @doc "Test hook: feed bytes; `gen` (the pty's damage generation) defaults to gen + 1."
  def write(vt, bin, gen \\ nil), do: GenServer.cast(vt, {:write, bin, gen})

  @doc "Makes the next `dirty_rows/1` return every row."
  def force_full(vt), do: GenServer.cast(vt, :force_full)

  @doc "Test hook: `mode` is an M1 mode atom (e.g. `:bracketed_paste`)."
  def set_mode(vt, mode, on?), do: GenServer.call(vt, {:set_mode, mode, on?})

  @doc "Test hook."
  def set_kitty_flags(vt, n), do: GenServer.call(vt, {:kitty, n})

  @impl HerdrServer.Kernel.Vt
  def resize(vt, cols, rows, _cell_px), do: GenServer.call(vt, {:resize, cols, rows})

  @impl HerdrServer.Kernel.Vt
  def dirty_rows(vt), do: GenServer.call(vt, :dirty_rows)

  @impl HerdrServer.Kernel.Vt
  def full_rows(vt), do: GenServer.call(vt, :full_rows)

  @impl HerdrServer.Kernel.Vt
  def read_text(vt, what), do: GenServer.call(vt, {:read_text, what})

  @impl HerdrServer.Kernel.Vt
  def scrollbar(vt), do: GenServer.call(vt, :scrollbar)

  @impl HerdrServer.Kernel.Vt
  def scroll_to(_vt, _offset), do: :ok

  @impl HerdrServer.Kernel.Vt
  def mode(vt, id), do: GenServer.call(vt, {:mode, id})

  @impl HerdrServer.Kernel.Vt
  def kitty_keyboard_flags(vt), do: GenServer.call(vt, :kitty)

  @impl HerdrServer.Kernel.Vt
  def link_at(_vt, _x, _y), do: nil

  @impl HerdrServer.Kernel.Vt
  def graphics_placements(_vt), do: []

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

  def handle_call({:read_text, what}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    range =
      case what do
        {:rows, r} -> r
        _ -> 0..(state.rows - 1)
      end

    text = Enum.map_join(range, "\n", &(state |> text_row(&1) |> String.trim_trailing()))
    {:reply, text, state}
  end

  def handle_call(:scrollbar, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, %{total: state.rows, viewport: state.rows, offset: 0}, state}
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

  def handle_call(:cursor, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, %{x: state.cx, y: state.cy, shape: :block, visible: true, blinking: false}, state}
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
        cy: min(state.cy, rows - 1)
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

  defp pack(state, y) do
    state.grid |> elem(y) |> Tuple.to_list() |> Enum.map(&%Cell{glyph: &1}) |> Cell.encode_row()
  end

  defp text_row(state, y) when y >= 0 and y < state.rows do
    state.grid |> elem(y) |> Tuple.to_list() |> Enum.map_join(&if(&1 == "", do: " ", else: &1))
  end

  defp text_row(_state, _y), do: ""

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
