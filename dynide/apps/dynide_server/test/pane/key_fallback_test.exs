defmodule DynideServer.Pane.KeyFallbackTest do
  use ExUnit.Case, async: true

  alias DynideServer.Pane.KeyFallback

  defp k(key, mods, text \\ nil), do: %{key: key, mods: mods, event: :press, text: text}

  test "hyper and meta are dropped whatever the pane negotiated" do
    for neg <- [true, false], m <- [[:hyper], [:meta], [:ctrl, :meta]] do
      assert KeyFallback.translate(k("a", m), neg) == :drop
    end
  end

  test "a negotiated pane gets the key unchanged, super included" do
    for key <- [k("c", [:super]), k(:enter, [:shift]), k("m", [:ctrl]), k("I", [:ctrl])] do
      assert KeyFallback.translate(key, true) == key
    end
  end

  test "super chords are dropped in a pane that negotiated nothing" do
    assert KeyFallback.translate(k("c", [:super]), false) == :drop
    assert KeyFallback.translate(k(:enter, [:super]), false) == :drop
  end

  test "legacy shell keys" do
    table = [
      {k(:enter, [:shift]), k(:enter, [])},
      {k(:enter, [:ctrl]), k(:enter, [])},
      {k(:enter, [:ctrl, :shift]), k(:enter, [])},
      {k(:enter, [:alt, :shift]), k(:enter, [:alt])},
      {k(:enter, [:alt]), k(:enter, [:alt])},
      {k(:enter, []), k(:enter, [])},
      {k("m", [:ctrl]), k(:enter, [])},
      {k("m", [:alt, :ctrl]), k(:enter, [:alt])},
      {k("i", [:ctrl]), k(:tab, [])},
      {k(:tab, [:ctrl]), k(:tab, [])},
      {k(:tab, [:alt, :ctrl]), k(:tab, [:alt])},
      {k("[", [:ctrl]), k(:escape, [])},
      {k("C", [:ctrl, :shift], "C"), k("c", [:ctrl])},
      {k("c", [:ctrl, :shift]), k("c", [:ctrl])},
      {k("C", [:ctrl]), k("c", [:ctrl])},
      {k("C", [:alt, :ctrl]), k("c", [:alt, :ctrl])},
      {k("I", [:ctrl]), k(:tab, [])},
      {k("M", [:ctrl, :shift]), k(:enter, [])},
      {k("c", [:ctrl]), k("c", [:ctrl])},
      {k("x", [:alt]), k("x", [:alt])},
      {k("1", [:ctrl, :shift]), k("1", [:ctrl, :shift])},
      {k(:tab, [:shift]), k(:tab, [:shift])}
    ]

    for {input, want} <- table do
      assert KeyFallback.translate(input, false) == want, "#{inspect(input)}"
    end
  end

  test "other fields of the event are kept" do
    ev = %{key: "m", mods: [:ctrl], event: :repeat, text: nil, extra: 1}
    assert KeyFallback.translate(ev, false) == %{ev | key: :enter, mods: []}
  end
end
