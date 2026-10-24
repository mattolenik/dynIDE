defmodule HerdrTerm.Client.Term.Input.Parse do
  @moduledoc """
  Pure parser from host-terminal input bytes to neutral `HerdrScene.Event` terms.
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
    * Unknown sequences and unmapped kitty functional codes are dropped.
  """

  import Bitwise

  alias HerdrScene.Event

  defstruct buffer: "", paste: nil, windows: %{}, kitty: false

  @type item :: Event.t() | {:reply, atom, term}
  @type t :: %__MODULE__{buffer: binary, paste: nil | iodata, windows: map, kitty: boolean}

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

  @spec flush(t) :: {[item], t}
  def flush(%__MODULE__{buffer: "\e"} = t), do: {[Event.key(:escape)], %{t | buffer: ""}}

  def flush(%__MODULE__{buffer: <<"\e", c>>} = t) when c in 0x20..0x7E,
    do: {[Event.key(<<c>>, [:alt])], %{t | buffer: ""}}

  def flush(%__MODULE__{} = t), do: {[], %{t | buffer: ""}}

  defp drain("", acc, t), do: {Enum.reverse(acc), %{t | buffer: ""}}

  defp drain(buf, acc, t) do
    case next(buf, t) do
      :more -> {Enum.reverse(acc), %{t | buffer: buf}}
      {items, rest, t} -> drain(rest, Enum.reverse(items, acc), t)
    end
  end

  # One sequence off the front of the buffer: :more | {items, rest, t}.
  defp next("\e", _t), do: :more
  defp next("\e[" <> rest, t), do: csi_scan(rest, 0, t)
  defp next("\eO", _t), do: :more

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
  defp csi_scan(bin, n, t) do
    case bin do
      <<_::binary-size(^n)>> ->
        :more

      <<_::binary-size(^n), c, _::binary>> when c in 0x20..0x3F ->
        csi_scan(bin, n + 1, t)

      <<body::binary-size(^n), f, rest::binary>> when f in 0x40..0x7E ->
        {csi(body, f, t), rest, t}

      # malformed: drop the introducer, resume at the offending byte
      <<_::binary-size(^n), _::binary>> ->
        {[], binary_part(bin, n, byte_size(bin) - n), t}
    end
  end

  # Task 9 adds clauses here for "<" (mouse), "200~" (paste), "I"/"O" (focus), "?" replies.
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
