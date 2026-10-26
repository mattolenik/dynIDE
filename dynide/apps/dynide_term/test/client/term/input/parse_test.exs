defmodule DynideTerm.Client.Term.Input.ParseTest do
  use ExUnit.Case, async: true

  alias DynideScene.Event
  alias DynideTerm.Client.Term.Input.Parse

  defp k(key, mods \\ [], opts \\ []), do: Event.key(key, mods, opts)
  defp t(s), do: k(s, [], text: s)

  defp parse(bin) do
    {evs, p} = Parse.events(bin, Parse.new())
    {more, _} = Parse.flush(p)
    evs ++ more
  end

  defp vectors do
    [
      {"a", [t("a")]},
      {"Z", [t("Z")]},
      {" ", [t(" ")]},
      {"é", [t("é")]},
      {"世", [t("世")]},
      {"😀", [t("😀")]},
      {"ab", [t("a"), t("b")]},
      {"\r", [k(:enter)]},
      {"\t", [k(:tab)]},
      {"\x7f", [k(:backspace)]},
      {"\b", [k(:backspace)]},
      {<<0>>, [k(" ", [:ctrl])]},
      {<<1>>, [k("a", [:ctrl])]},
      {<<3>>, [k("c", [:ctrl])]},
      {<<10>>, [k("j", [:ctrl])]},
      {<<26>>, [k("z", [:ctrl])]},
      {<<28>>, [k("\\", [:ctrl])]},
      {<<29>>, [k("]", [:ctrl])]},
      {<<30>>, [k("^", [:ctrl])]},
      {<<31>>, [k("_", [:ctrl])]},
      {"\e", [k(:escape)]},
      {"\ea", [k("a", [:alt])]},
      {"\eA", [k("A", [:alt])]},
      {"\e[", [k("[", [:alt])]},
      {"\eO", [k("O", [:alt])]},
      {"\eé", [k("é", [:alt])]},
      {"\e\r", [k(:enter, [:alt])]},
      {"\e\x7f", [k(:backspace, [:alt])]},
      {"\e\e", [k(:escape), k(:escape)]},
      {"\e[A", [k(:up)]},
      {"\e[B", [k(:down)]},
      {"\e[C", [k(:right)]},
      {"\e[D", [k(:left)]},
      {"\eOA", [k(:up)]},
      {"\eOD", [k(:left)]},
      {"\e[H", [k(:home)]},
      {"\e[F", [k(:end)]},
      {"\eOH", [k(:home)]},
      {"\e[Z", [k(:tab, [:shift])]},
      {"\e[1;5A", [k(:up, [:ctrl])]},
      {"\e[1;2B", [k(:down, [:shift])]},
      {"\e[1;3C", [k(:right, [:alt])]},
      {"\e[1;8D", [k(:left, [:alt, :ctrl, :shift])]},
      {"\e[1;9H", [k(:home, [:super])]},
      {"\e[1;17F", [k(:end, [:hyper])]},
      {"\e[1;33A", [k(:up, [:meta])]},
      {"\e[1;65A", [k(:up, [:caps_lock])]},
      {"\e[1;129A", [k(:up, [:num_lock])]},
      {"\e[1;1:3A", [k(:up, [], event: :release)]},
      {"\e[1;5:2A", [k(:up, [:ctrl], event: :repeat)]},
      {"\e[1~", [k(:home)]},
      {"\e[2~", [k(:insert)]},
      {"\e[3~", [k(:delete)]},
      {"\e[4~", [k(:end)]},
      {"\e[5~", [k(:page_up)]},
      {"\e[6~", [k(:page_down)]},
      {"\e[7~", [k(:home)]},
      {"\e[8~", [k(:end)]},
      {"\e[3;2~", [k(:delete, [:shift])]},
      {"\e[5;5~", [k(:page_up, [:ctrl])]},
      {"\eOP", [k(:f1)]},
      {"\eOQ", [k(:f2)]},
      {"\eOR", [k(:f3)]},
      {"\eOS", [k(:f4)]},
      {"\e[1;2P", [k(:f1, [:shift])]},
      {"\e[11~", [k(:f1)]},
      {"\e[15~", [k(:f5)]},
      {"\e[17~", [k(:f6)]},
      {"\e[18~", [k(:f7)]},
      {"\e[19~", [k(:f8)]},
      {"\e[20~", [k(:f9)]},
      {"\e[21~", [k(:f10)]},
      {"\e[23~", [k(:f11)]},
      {"\e[24~", [k(:f12)]},
      {"\e[15;5~", [k(:f5, [:ctrl])]},
      {"\e[97u", [t("a")]},
      {"\e[97;5u", [k("a", [:ctrl])]},
      {"\e[97;1:3u", [k("a", [], event: :release)]},
      {"\e[97;1:2u", [k("a", [], event: :repeat, text: "a")]},
      {"\e[97;2u", [t("A")]},
      {"\e[97:65;2u", [t("A")]},
      {"\e[97:65:97;6u", [k("A", [:ctrl])]},
      {"\e[49:33;2u", [t("!")]},
      {"\e[49;2u", [k("1", [:shift], text: "1")]},
      {"\e[97;;228u", [k("a", [], text: "ä")]},
      {"\e[233u", [t("é")]},
      {"\e[32u", [t(" ")]},
      {"\e[32;5u", [k(" ", [:ctrl])]},
      {"\e[13u", [k(:enter)]},
      {"\e[9u", [k(:tab)]},
      {"\e[9;2u", [k(:tab, [:shift])]},
      {"\e[127u", [k(:backspace)]},
      {"\e[27u", [k(:escape)]},
      {"\e[27;3u", [k(:escape, [:alt])]},
      {"\e[57414u", [k(:enter)]},
      {"\e[57399u", [t("0")]},
      {"\e[57408u", [t("9")]},
      {"\e[57419u", [k(:up)]},
      {"\e[57426;5u", [k(:delete, [:ctrl])]},
      {"\e[57358u", []},
      {"\e[57376u", []},
      {"\e[?1;2c", []},
      {"\e[1200000u", []},
      {"\xff", []},
      {"\xffa", [t("a")]}
    ]
  end

  test "vector table" do
    assert length(vectors()) >= 40

    for {bin, expected} <- vectors() do
      assert parse(bin) == expected, "bytes #{inspect(bin)}"
      Enum.each(expected, &assert(Event.validate(&1) == :ok))
    end
  end

  test "lone ESC and partial sequences stay buffered until flush" do
    p = Parse.new()
    assert {[], p1} = Parse.events("\e", p)
    assert p1.buffer == "\e"
    assert {[{:key, %{key: :escape}}], %{buffer: ""}} = Parse.flush(p1)
    assert {[], p2} = Parse.events("\e[1;", p)
    assert {[{:key, %{key: :up, mods: [:ctrl]}}], %{buffer: ""}} = Parse.events("5A", p2)
    assert {[], p3} = Parse.events(<<0xC3>>, p)
    assert {[{:key, %{key: "é"}}], _} = Parse.events(<<0xA9>>, p3)
    assert {[], _} = Parse.flush(p3)
  end

  test "split anywhere equals whole" do
    for {bin, _} <- vectors() do
      bytewise =
        for(<<b <- bin>>, do: <<b>>)
        |> Enum.reduce({[], Parse.new()}, fn b, {acc, p} ->
          {evs, p} = Parse.events(b, p)
          {acc ++ evs, p}
        end)
        |> then(fn {acc, p} -> acc ++ elem(Parse.flush(p), 0) end)

      assert bytewise == parse(bin), "bytes #{inspect(bin)}"
    end
  end

  # Fake kernel encode_key vectors (Task 2), copied as literals.
  test "fake kernel encode_key vectors parse back" do
    assert parse("a") == [t("a")]
    assert parse(<<3>>) == [k("c", [:ctrl])]
    assert parse("\ex") == [k("x", [:alt])]
    assert parse("\e[1;2A") == [k(:up, [:shift])]
    assert parse("\e[A") == [k(:up)]
    assert parse("\r") == [k(:enter)]
    assert parse("\x7f") == [k(:backspace)]
    assert parse("\e[5~") == [k(:page_up)]
    assert parse("\eOP") == [k(:f1)]
  end

  test "over-long CSI is bounded and swallowed" do
    junk = "\e[" <> String.duplicate("1", 10_000)

    for chunks <- [[junk], for(<<c::binary-size(100) <- junk>>, do: c)] do
      p =
        Enum.reduce(chunks, Parse.new(), fn c, p ->
          {[], p} = Parse.events(c, p)
          assert byte_size(p.buffer) <= 64
          p
        end)

      assert {[], p} = Parse.events("1m", p)
      assert {[{:key, %{key: "a"}}], _} = Parse.events("a", p)
    end
  end

  test "flush of ESC plus partial UTF-8 emits escape; unknown SS3 is dropped" do
    {[], p} = Parse.events(<<"\e", 0xC3>>, Parse.new())
    assert {[{:key, %{key: :escape}}], %{buffer: ""}} = Parse.flush(p)
    assert parse("\eOz") == []
  end
end
