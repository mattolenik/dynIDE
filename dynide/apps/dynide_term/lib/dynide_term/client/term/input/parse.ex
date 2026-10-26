defmodule DynideTerm.Client.Term.Input.Parse do
  @moduledoc """
  Pure parser from host-terminal input bytes to neutral `DynideScene.Event` terms.
  Part 1 handles keys: UTF-8 text, C0 controls, legacy CSI/SS3 and kitty CSI u.
  Semantics follow `src/raw_input.rs`.

  `events/2` consumes bytes and keeps any incomplete trailing sequence in
  `buffer`; `flush/1` (called after the ESC timeout) resolves a buffered lone
  ESC to `:escape` and `ESC <printable byte>` to alt+key. New sequence kinds
  (mouse, paste, focus, replies) slot into `next/2` / `csi/3`.

  ## Normalization rules

    * `text` is the typed text for printable keys: the key itself when the event
      is not a release and the modifiers are at most shift/caps_lock/num_lock
      (or the kitty associated-text field when present). Ctrl/alt combos, named
      keys and releases have `text: nil`.
    * Shifted letters are normalized to the shifted glyph without `:shift`:
      `\\e[97;2u` and `\\e[97:65;2u` both give `key: "A"`, `mods: []`. A kitty
      shifted-key field also replaces the key for non-letters (`!` for shift+1).
    * `\\0` is ctrl+space (`key: " "`); `\\e[Z` is shift+tab.
    * A CSI with more than 64 parameter bytes is malformed and swallowed
      through its final byte (state `skip`); it is never buffered unboundedly.
    * `flush/1` of ESC plus a partial UTF-8 character emits `:escape` and drops
      the partial bytes.
    * SGR mouse (`\\e[<b;x;y M|m`), focus (`\\e[I`/`\\e[O`) and bracketed paste are
      always parsed. Paste bodies are buffered (across chunks) until `\\e[201~`
      and never parsed as keys; the 64-byte CSI cap does not apply. A body that
      grows past 16 MiB (`paste_max/0`) without its end marker is emitted as one
      `{:paste, binary}` so far and buffering starts over, still in paste mode
      (so the rest of the paste is never typed as keys); one long paste then
      arrives as several `{:paste, _}` events.
    * Query replies (DA1, kitty flags, colours, cursor position) are emitted as
      `{:reply, kind, data}` only while a window opened with `open_window/3` is
      live, else dropped. A DA1 reply closes all windows but `:colors` (a late startup
      DA1 must not end a colour query); the DSR status reply `\\e[0n` inside `:colors`
      is the colour query's end sentinel, `{:reply, :colors_end, nil}`, and closes it.
      Colour replies (`:colors` window): OSC 10/11 -> `{:reply, :fg | :bg, {r, g, b}}`, OSC 4 ->
      `{:reply, :palette, {n, {r, g, b}}}`, from `rgb:` specs of 1-4 hex digits per
      channel (anything else is dropped). An OSC reply body over 256 bytes without
      terminator is dropped.
    * Colour scheme reports `\\e[?997;1n` / `\\e[?997;2n` are always parsed, as
      `{:reply, :scheme, :dark | :light}` (the host sends them unsolicited in mode 2031).
    * Ambiguity: a cursor-position reply `\\e[row;colR` looks like legacy F3 with
      modifiers `\\e[1;modsR`. With a `:cpr` window open it is a reply; outside a
      window `\\e[1;<mods>R` is F3 and any other two-number `R` is dropped
      (a CPR for row 1 outside a window is therefore read as F3).
    * Unknown sequences (including unknown SS3 finals such as `\\eOz`) and unmapped kitty functional codes are dropped.
  """

  import Bitwise

  alias DynideScene.Event

  defstruct buffer: "", paste: nil, windows: %{}, kitty: false, skip: false

  @type item :: Event.t() | {:reply, atom, term}
  @type t :: %__MODULE__{
          buffer: binary,
          paste: nil | binary,
          windows: map,
          kitty: boolean,
          skip: boolean | :osc
        }

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
  @letter_finals %{?A => :up, ?B => :down, ?C => :right, ?D => :left, ?H => :home, ?F => :end}
  @ss3_finals Map.merge(@letter_finals, %{?P => :f1, ?Q => :f2, ?R => :f3, ?S => :f4})
  @tilde %{
    1 => :home,
    2 => :insert,
    3 => :delete,
    4 => :end,
    5 => :page_up,
    6 => :page_down,
    7 => :home,
    8 => :end,
    11 => :f1,
    12 => :f2,
    13 => :f3,
    14 => :f4,
    15 => :f5,
    17 => :f6,
    18 => :f7,
    19 => :f8,
    20 => :f9,
    21 => :f10,
    23 => :f11,
    24 => :f12
  }
  @kitty_named %{
    27 => :escape,
    13 => :enter,
    9 => :tab,
    127 => :backspace,
    8 => :backspace,
    57_414 => :enter,
    57_417 => :left,
    57_418 => :right,
    57_419 => :up,
    57_420 => :down,
    57_421 => :page_up,
    57_422 => :page_down,
    57_423 => :home,
    57_424 => :end,
    57_425 => :insert,
    57_426 => :delete
  }
  # keypad digits and operators arrive as their printable glyph
  @kitty_keypad Map.merge(
                  Map.new(Enum.with_index(~w(0 1 2 3 4 5 6 7 8 9), 57_399), fn {g, c} ->
                    {c, g}
                  end),
                  %{
                    57_409 => ".",
                    57_410 => "/",
                    57_411 => "*",
                    57_412 => "-",
                    57_413 => "+",
                    57_415 => "=",
                    57_416 => ","
                  }
                )

  @spec new() :: t
  def new, do: %__MODULE__{}

  @spec events(binary, t) :: {[item], t}
  def events(bin, %__MODULE__{} = t), do: drain(t.buffer <> bin, [], t)

  @spec open_window(t, :da1 | :kitty_flags | :colors | :cpr, integer) :: t
  def open_window(%__MODULE__{} = t, kind, deadline_ms)
      when kind in [:da1, :kitty_flags, :colors, :cpr],
      do: %{t | windows: Map.put(t.windows, kind, deadline_ms)}

  @spec expire_windows(t, integer) :: t
  def expire_windows(%__MODULE__{} = t, now_ms),
    do: %{t | windows: Map.reject(t.windows, fn {_, d} -> d <= now_ms end)}

  @spec flush(t) :: {[item], t}
  def flush(%__MODULE__{buffer: "\e"} = t), do: {[Event.key(:escape)], %{t | buffer: ""}}

  def flush(%__MODULE__{buffer: <<"\e", c>>} = t) when c in 0x20..0x7E,
    do: {[Event.key(<<c>>, [:alt])], %{t | buffer: ""}}

  # ESC followed by a partial UTF-8 character: emit :escape, drop the partial bytes.
  def flush(%__MODULE__{buffer: <<"\e", c, _::binary>>} = t) when c >= 0xC2,
    do: {[Event.key(:escape)], %{t | buffer: ""}}

  def flush(%__MODULE__{} = t), do: {[], %{t | buffer: "", skip: false}}

  @paste_max 16 * 1024 * 1024

  @doc "Paste body cap in bytes (see moduledoc)."
  @spec paste_max() :: pos_integer
  def paste_max, do: @paste_max

  defp drain("", acc, t), do: {Enum.reverse(acc), %{t | buffer: ""}}

  # Inside bracketed paste: accumulate until the end marker.
  defp drain(buf, acc, %__MODULE__{paste: p} = t) when is_binary(p) do
    all = p <> buf
    start = max(byte_size(p) - 5, 0)

    case :binary.match(all, "\e[201~", scope: {start, byte_size(all) - start}) do
      {pos, 6} ->
        rest = binary_part(all, pos + 6, byte_size(all) - pos - 6)
        drain(rest, [{:paste, binary_part(all, 0, pos)} | acc], %{t | paste: nil})

      # over the cap: emit the body so far, keep 5 bytes that may start the marker
      :nomatch when byte_size(all) > @paste_max ->
        cut = byte_size(all) - 5
        tail = binary_part(all, cut, 5)
        {Enum.reverse([{:paste, binary_part(all, 0, cut)} | acc]), %{t | buffer: "", paste: tail}}

      :nomatch ->
        {Enum.reverse(acc), %{t | buffer: "", paste: all}}
    end
  end

  # Inside an over-long OSC reply: swallow up to BEL / ST.
  defp drain(buf, acc, %__MODULE__{skip: :osc} = t) do
    case :binary.match(buf, ["\a", "\e\\"]) do
      {pos, len} ->
        rest = binary_part(buf, pos + len, byte_size(buf) - pos - len)
        drain(rest, acc, %{t | skip: false})

      :nomatch ->
        {Enum.reverse(acc), %{t | buffer: keep_esc(buf)}}
    end
  end

  # Inside an over-long CSI: swallow parameter bytes up to and including the final byte.
  defp drain(buf, acc, %__MODULE__{skip: true} = t) do
    case skip(buf) do
      {:done, rest} -> drain(rest, acc, %{t | skip: false})
      :all -> {Enum.reverse(acc), %{t | buffer: ""}}
    end
  end

  defp drain(buf, acc, t) do
    case next(buf, t) do
      :more -> {Enum.reverse(acc), %{t | buffer: buf}}
      {items, rest, t} -> drain(rest, Enum.reverse(items, acc), t)
    end
  end

  # One sequence off the front of the buffer: :more | {items, rest, t}.
  defp next("\e", _t), do: :more
  defp next("\e[200~" <> rest, t), do: {[], rest, %{t | paste: ""}}
  defp next("\e[" <> rest, t), do: csi_scan(rest, 0, t)
  defp next("\eO", _t), do: :more
  defp next("\e]" <> rest, _t) when rest in ["", "1", "4", "10", "11"], do: :more
  defp next("\e]4;" <> rest, t), do: osc(4, rest, t)

  defp next(<<"\e]", n::binary-size(2), ";", rest::binary>>, t) when n in ["10", "11"],
    do: osc(String.to_integer(n), rest, t)

  defp next(<<"\eO", c, rest::binary>>, t),
    do: {List.wrap(named(@ss3_finals[c], [], :press)), rest, t}

  defp next("\e\e" <> rest, t), do: {[Event.key(:escape)], "\e" <> rest, t}

  defp next("\e" <> rest, t) do
    case plain(rest) do
      :more -> :more
      {items, rest} -> {Enum.map(items, &alt/1), rest, t}
    end
  end

  defp next(bin, t) do
    case plain(bin) do
      :more -> :more
      {items, rest} -> {items, rest, t}
    end
  end

  defp alt({:key, %{key: k, mods: m, event: e}}), do: Event.key(k, [:alt | m], event: e)

  # -- plain bytes: C0 and UTF-8 text ---------------------------------------
  defp plain(<<0, r::binary>>), do: {[Event.key(" ", [:ctrl])], r}
  defp plain(<<?\r, r::binary>>), do: {[Event.key(:enter)], r}
  defp plain(<<?\t, r::binary>>), do: {[Event.key(:tab)], r}
  defp plain(<<b, r::binary>>) when b in [0x7F, 0x08], do: {[Event.key(:backspace)], r}
  defp plain(<<b, r::binary>>) when b in 1..26, do: {[Event.key(<<?a + b - 1>>, [:ctrl])], r}
  defp plain(<<b, r::binary>>) when b in 0x1C..0x1F, do: {[Event.key(<<b + 0x40>>, [:ctrl])], r}
  defp plain(<<c::utf8, r::binary>>), do: {[text_key(<<c::utf8>>)], r}

  defp plain(<<_, r::binary>> = bin),
    do: if(partial_utf8?(bin), do: :more, else: {[], r})

  defp text_key(g), do: Event.key(g, [], text: g)

  defp partial_utf8?(<<b, rest::binary>>) do
    need =
      cond do
        b in 0xC2..0xDF -> 1
        b in 0xE0..0xEF -> 2
        b in 0xF0..0xF4 -> 3
        true -> nil
      end

    need != nil and byte_size(rest) < need and
      for(<<c <- rest>>, do: c) |> Enum.all?(&(&1 in 0x80..0xBF))
  end

  # -- CSI ------------------------------------------------------------------
  defp skip(<<c, r::binary>>) when c in 0x20..0x3F, do: skip(r)
  defp skip(<<c, r::binary>>) when c in 0x40..0x7E, do: {:done, r}
  defp skip(""), do: :all
  defp skip(bin), do: {:done, bin}

  # A CSI longer than this many parameter bytes is malformed: dropped, not buffered.
  @max_csi 64

  defp csi_scan(bin, n, t) do
    case bin do
      <<_::binary-size(^n), _::binary>> when n >= @max_csi ->
        {[], binary_part(bin, n, byte_size(bin) - n), %{t | skip: true}}

      <<_::binary-size(^n)>> ->
        :more

      <<_::binary-size(^n), c, _::binary>> when c in 0x20..0x3F ->
        csi_scan(bin, n + 1, t)

      <<body::binary-size(^n), f, rest::binary>> when f in 0x40..0x7E ->
        reply(body, f, rest, t)

      # malformed: drop the introducer, resume at the offending byte
      <<_::binary-size(^n), _::binary>> ->
        {[], binary_part(bin, n, byte_size(bin) - n), t}
    end
  end

  defp csi("", ?I, _t), do: [{:focus, true}]
  defp csi("", ?O, _t), do: [{:focus, false}]
  defp csi("<" <> body, f, _t) when f in [?M, ?m], do: mouse(body, f)

  # DA1 reply: sentinel, closes every window (handled in csi_scan, which owns t).
  defp csi("?" <> _, _f, _t), do: []
  defp csi(body, ?u, _t), do: kitty(fields(body))
  defp csi(_body, ?Z, _t), do: [Event.key(:tab, [:shift])]

  defp csi(body, f, _t) when is_map_key(@letter_finals, f) or f in [?P, ?Q, ?R, ?S],
    do: legacy(@ss3_finals[f], fields(body))

  defp csi(body, ?~, _t) do
    case fields(body) do
      [[n | _] | _] = fs when is_map_key(@tilde, n) -> legacy(@tilde[n], fs)
      _ -> []
    end
  end

  defp csi(_body, _f, _t), do: []

  # Replies need window state; everything else is stateless via csi/3.
  defp reply("?" <> p, ?c, rest, t) do
    items = if is_map_key(t.windows, :da1), do: [{:reply, :da1, params(p)}], else: []
    {items, rest, %{t | windows: Map.take(t.windows, [:colors])}}
  end

  defp reply("0", ?n, rest, %{windows: %{colors: _}} = t),
    do: {[{:reply, :colors_end, nil}], rest, %{t | windows: Map.delete(t.windows, :colors)}}

  defp reply("?" <> p, ?u, rest, t) do
    with true <- is_map_key(t.windows, :kitty_flags), n when is_integer(n) <- int(p) do
      {[{:reply, :kitty_flags, n}], rest, %{t | kitty: true}}
    else
      _ -> {[], rest, t}
    end
  end

  defp reply("?997;" <> s, ?n, rest, t) when s in ["1", "2"],
    do: {[{:reply, :scheme, if(s == "1", do: :dark, else: :light)}], rest, t}

  defp reply(body, ?R, rest, t) do
    case Regex.run(~r/\A(\d+);(\d+)\z/, body) do
      [_, r, c] ->
        cond do
          is_map_key(t.windows, :cpr) -> {[{:reply, :cpr, {int(r), int(c)}}], rest, t}
          r == "1" -> {csi(body, ?R, t), rest, t}
          true -> {[], rest, t}
        end

      _ ->
        {csi(body, ?R, t), rest, t}
    end
  end

  defp reply(body, f, rest, t), do: {csi(body, f, t), rest, t}

  defp params(p), do: p |> String.split(";") |> Enum.flat_map(&List.wrap(int(&1)))

  # -- mouse ------------------------------------------------------------------
  defp mouse(body, f) do
    with [b, x, y] <- String.split(body, ";"),
         b when is_integer(b) <- int(b),
         x when is_integer(x) <- int(x),
         y when is_integer(y) <- int(y),
         true <- b < 128 and (b &&& 96) != 96 and x >= 1 and y >= 1 do
      [{:mouse, mouse_map(b, f, x - 1, y - 1)}]
    else
      _ -> []
    end
  end

  defp mouse_map(b, f, x, y) do
    mods = for {bit, m} <- [{4, :shift}, {8, :alt}, {16, :ctrl}], (b &&& bit) != 0, do: m
    low = b &&& 3
    btn = Enum.at([:left, :middle, :right, :none], low)

    {kind, button} =
      cond do
        (b &&& 64) != 0 ->
          {:scroll, Enum.at([:wheel_up, :wheel_down, :wheel_left, :wheel_right], low)}

        (b &&& 32) != 0 ->
          {if(btn == :none, do: :move, else: :drag), btn}

        f == ?m ->
          {:release, btn}

        true ->
          {:press, btn}
      end

    %{kind: kind, button: button, x: x, y: y, mods: Enum.sort(mods), px: nil}
  end

  # -- OSC 10/11/4 colour replies --------------------------------------------
  @max_osc 256

  defp osc(n, rest, t) do
    case :binary.match(rest, ["\a", "\e\\"]) do
      {pos, len} ->
        after_term = binary_part(rest, pos + len, byte_size(rest) - pos - len)

        items =
          if pos <= @max_osc,
            do: colors(n, binary_part(rest, 0, pos), t),
            else: []

        {items, after_term, t}

      :nomatch when byte_size(rest) > @max_osc ->
        {[], keep_esc(rest), %{t | skip: :osc}}

      :nomatch ->
        :more
    end
  end

  defp colors(n, d, t),
    do: if(is_map_key(t.windows, :colors), do: List.wrap(color(n, d)), else: [])

  defp color(4, d) do
    with [i, spec] <- String.split(d, ";", parts: 2),
         n when n in 0..255 <- int(i),
         {_, _, _} = c <- rgb(spec),
         do: {:reply, :palette, {n, c}},
         else: (_ -> nil)
  end

  defp color(n, d), do: if(c = rgb(d), do: {:reply, if(n == 10, do: :fg, else: :bg), c})

  # `rgb:R/G/B`, 1-4 hex digits per channel, scaled to 0..255
  defp rgb(spec) do
    case Regex.run(
           ~r/\Argb:([[:xdigit:]]{1,4})\/([[:xdigit:]]{1,4})\/([[:xdigit:]]{1,4})\z/,
           spec
         ) do
      [_ | hs] -> hs |> Enum.map(&chan/1) |> List.to_tuple()
      nil -> nil
    end
  end

  defp chan(h), do: round(String.to_integer(h, 16) * 255 / (Integer.pow(16, byte_size(h)) - 1))

  defp keep_esc(bin), do: if(String.ends_with?(bin, "\e"), do: "\e", else: "")

  defp legacy(name, fs) do
    {mods, event} = mods_event(Enum.at(fs, 1))
    List.wrap(named(name, mods, event))
  end

  defp named(nil, _mods, _event), do: nil
  defp named(name, mods, event), do: Event.key(name, mods, event: event)

  # "a:b;c" -> [[a, b], [c]] with nil for empty/non-numeric.
  defp fields(body), do: body |> String.split(";") |> Enum.map(&subfields/1)

  defp subfields(f), do: f |> String.split(":") |> Enum.map(&int/1)

  defp int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp mods_event(nil), do: {[], :press}

  defp mods_event([m | e]) do
    bits = max((m || 1) - 1, 0)
    {for({name, b} <- @mod_bits, (bits &&& b) != 0, do: name), event(e)}
  end

  defp event([2 | _]), do: :repeat
  defp event([3 | _]), do: :release
  defp event(_), do: :press

  # -- kitty CSI u ------------------------------------------------------------
  defp kitty(fs) do
    [code | rest] = Enum.at(fs, 0)
    shifted = List.first(rest)
    {mods, event} = mods_event(Enum.at(fs, 1))

    case key_of(code) do
      nil ->
        []

      key when is_atom(key) ->
        [Event.key(key, mods, event: event)]

      key ->
        {key, mods} = shift(key, shifted, mods)
        [Event.key(key, mods, event: event, text: kitty_text(Enum.at(fs, 2), key, mods, event))]
    end
  end

  defp key_of(nil), do: nil
  defp key_of(c) when is_map_key(@kitty_named, c), do: @kitty_named[c]
  defp key_of(c) when is_map_key(@kitty_keypad, c), do: @kitty_keypad[c]

  defp key_of(c) when c in 32..0xD7FF or c in 0xE000..0x10FFFF,
    do: if(c in 57_344..63_743, do: nil, else: <<c::utf8>>)

  defp key_of(_), do: nil

  defp shift(key, shifted, mods) do
    glyph = if is_integer(shifted) and key_of(shifted) |> is_binary(), do: key_of(shifted)
    up = String.upcase(key)

    cond do
      :shift not in mods -> {key, mods}
      glyph -> {glyph, mods -- [:shift]}
      up != key and String.length(up) == 1 -> {up, mods -- [:shift]}
      true -> {key, mods}
    end
  end

  defp kitty_text(cps, key, mods, event) do
    assoc =
      if is_list(cps) and event != :release, do: for(c <- cps, c, into: "", do: key_of(c) || "")

    cond do
      assoc not in [nil, ""] -> assoc
      event == :release -> nil
      mods -- [:caps_lock, :num_lock, :shift] == [] -> key
      true -> nil
    end
  end
end
