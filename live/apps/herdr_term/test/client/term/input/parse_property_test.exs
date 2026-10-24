defmodule HerdrTerm.Client.Term.Input.ParsePropertyTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias HerdrScene.Event
  alias HerdrTerm.Client.Term.Input.Parse

  @bits [shift: 1, alt: 2, ctrl: 4, super: 8, hyper: 16, meta: 32, caps_lock: 64, num_lock: 128]
  @printable ["a", "z", "A", "Q", "1", "!", "[", "~", " ", "é", "É", "世", "😀", "\\"]
  @csi_named %{
    up: {1, ?A},
    down: {1, ?B},
    right: {1, ?C},
    left: {1, ?D},
    home: {1, ?H},
    end: {1, ?F},
    f1: {1, ?P},
    f2: {1, ?Q},
    f3: {1, ?R},
    f4: {1, ?S},
    insert: {2, ?~},
    delete: {3, ?~},
    page_up: {5, ?~},
    page_down: {6, ?~},
    f5: {15, ?~},
    f6: {17, ?~},
    f7: {18, ?~},
    f8: {19, ?~},
    f9: {20, ?~},
    f10: {21, ?~},
    f11: {23, ?~},
    f12: {24, ?~}
  }
  @csi_u_named %{enter: 13, tab: 9, backspace: 127, escape: 27}
  @cases 2000

  defp pick(l), do: Enum.at(l, :rand.uniform(length(l)) - 1)
  defp subset(l), do: Enum.filter(l, fn _ -> :rand.uniform(2) == 1 end)

  # Expected text rule (moduledoc): printable key, not a release, no ctrl/alt/super/...
  defp text(k, mods, ev),
    do:
      if(is_binary(k) and ev != :release and mods -- [:caps_lock, :num_lock, :shift] == [], do: k)

  defp ev(key, mods, event), do: Event.key(key, mods, event: event, text: text(key, mods, event))

  defp m_param(mods), do: 1 + Enum.reduce(mods, 0, &(&2 ||| @bits[&1]))
  defp e_code(:press), do: 1
  defp e_code(:repeat), do: 2
  defp e_code(:release), do: 3

  defp letter?(g),
    do: String.upcase(g) != String.downcase(g) and String.length(String.upcase(g)) == 1

  # -- CSI u encoder (kitty, report all events) ------------------------------
  defp enc_u({:key, %{key: key, mods: mods, event: event}}) do
    mp = "#{m_param(mods)}:#{e_code(event)}"

    case u_code(key) do
      nil -> csi_named(key, mp)
      {code, nil} when mods == [] and event == :press -> "\e[#{code}u"
      {code, nil} -> "\e[#{code};#{mp}u"
      {code, up} -> "\e[#{code}:#{up};#{m_param([:shift | mods])}:#{e_code(event)}u"
    end
  end

  defp csi_named(key, mp) do
    {n, f} = @csi_named[key]
    lead = if f == ?~, do: "#{n}", else: "1"
    "\e[#{lead};#{mp}" <> <<f>>
  end

  # {code, shifted} | nil for CSI-form named keys
  defp u_code(key) when is_atom(key), do: if(u = @csi_u_named[key], do: {u, nil})

  defp u_code(key) do
    <<cp::utf8>> = String.downcase(key)
    <<up::utf8>> = key
    if letter?(key) and key == String.upcase(key), do: {cp, up}, else: {up, nil}
  end

  # -- legacy encoder (press only) -------------------------------------------
  defp enc_legacy({:key, %{key: key, mods: mods}}) do
    csi? = key not in [:enter, :tab, :backspace] and is_atom(key)
    alt = if :alt in mods and not csi?, do: "\e", else: ""
    alt <> enc_legacy_key(key, mods -- [:alt], mods)
  end

  defp enc_legacy_key(:enter, _, _), do: "\r"
  defp enc_legacy_key(:tab, _, _), do: "\t"
  defp enc_legacy_key(:backspace, _, _), do: "\x7f"
  defp enc_legacy_key(key, _, mods) when is_atom(key), do: enc_csi(key, mods)
  defp enc_legacy_key(" ", [:ctrl], _), do: <<0>>
  defp enc_legacy_key("\\", [:ctrl], _), do: <<0x1C>>
  defp enc_legacy_key(<<c>>, [:ctrl], _), do: <<c - ?a + 1>>
  defp enc_legacy_key(key, [], _), do: key

  defp enc_csi(key, mods) do
    {n, f} = @csi_named[key]
    sfx = if mods == [], do: "", else: ";#{m_param(mods)}"

    cond do
      f == ?~ -> "\e[#{n}#{sfx}~"
      mods == [] and key in [:f1, :f2, :f3, :f4] -> "\eO" <> <<f>>
      mods == [] -> "\e[" <> <<f>>
      true -> "\e[1#{sfx}" <> <<f>>
    end
  end

  defp parse_all(bin) do
    {evs, p} = Parse.events(bin, Parse.new())
    evs ++ elem(Parse.flush(p), 0)
  end

  defp gen_u do
    event = pick([:press, :repeat, :release])
    mods = subset(Keyword.keys(@bits))

    key =
      if :rand.uniform(2) == 1,
        do: pick(Map.keys(@csi_named) ++ Map.keys(@csi_u_named)),
        else: pick(@printable)

    # Shift on a letter is carried by the glyph: the normalized event has no :shift.
    {key, mods} =
      if is_binary(key) and letter?(key) and (:shift in mods or key == String.upcase(key)),
        do: {String.upcase(key), mods -- [:shift]},
        else: {key, mods}

    ev(key, mods, event)
  end

  defp gen_legacy do
    case :rand.uniform(4) do
      1 -> ev(pick(Map.keys(@csi_named)), subset(Keyword.keys(@bits)), :press)
      2 -> ev(pick([:enter, :tab, :backspace]), subset([:alt]), :press)
      3 -> ev(pick(~w(a b c k z) ++ [" ", "\\"]), pick([[:ctrl], [:ctrl, :alt]]), :press)
      4 -> ev(pick(@printable -- ["["]), subset([:alt]), :press)
    end
  end

  test "kitty CSI u round trip" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..@cases do
      evs = for _ <- 1..:rand.uniform(4), do: gen_u()
      assert Enum.all?(evs, &(Event.validate(&1) == :ok))
      bin = evs |> Enum.map(&enc_u/1) |> IO.iodata_to_binary()
      assert parse_all(bin) == evs, "bytes #{inspect(bin)}"
    end
  end

  test "legacy round trip" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..@cases do
      evs = for _ <- 1..:rand.uniform(4), do: gen_legacy()
      bin = evs |> Enum.map(&enc_legacy/1) |> IO.iodata_to_binary()
      parsed = parse_all(bin)
      assert parsed == evs, "bytes #{inspect(bin)}"
      assert Enum.all?(parsed, &(Event.validate(&1) == :ok))
    end
  end
end
