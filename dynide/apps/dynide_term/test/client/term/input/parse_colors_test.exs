defmodule DynideTerm.Client.Term.Input.ParseColorsTest do
  use ExUnit.Case, async: true

  alias DynideTerm.Client.Term.Input.Parse

  defp colors,
    do: Parse.open_window(Parse.new(), :colors, System.monotonic_time(:millisecond) + 1000)

  defp run(bin, t), do: bin |> Parse.events(t) |> elem(0)

  test "OSC 4 palette replies, any channel width, either terminator" do
    assert run("\e]4;1;rgb:ffff/0000/0000\e\\", colors()) == [
             {:reply, :palette, {1, {255, 0, 0}}}
           ]

    assert run("\e]4;255;rgb:80/ff/0\a", colors()) == [{:reply, :palette, {255, {128, 255, 0}}}]
    assert run("\e]4;7;rgb:f/8/0\a", colors()) == [{:reply, :palette, {7, {255, 136, 0}}}]
  end

  test "OSC 10/11 replies become rgb" do
    assert run("\e]10;rgb:ffff/ffff/ffff\e\\\e]11;rgb:1e1e/1e1e/2e2e\e\\", colors()) ==
             [{:reply, :fg, {255, 255, 255}}, {:reply, :bg, {30, 30, 46}}]
  end

  test "a reply split across chunks" do
    {[], t} = Parse.events("\e]", colors())
    {[], t} = Parse.events("4", t)
    {[], t} = Parse.events(";3;rgb:00", t)
    assert {[{:reply, :palette, {3, {0, 0, 255}}}], _} = Parse.events("/00/ff\a", t)
  end

  test "malformed or out-of-range colours and replies outside the window are dropped" do
    for bad <- [
          "\e]4;256;rgb:ff/00/00\a",
          "\e]4;x;rgb:ff/00/00\a",
          "\e]4;1;rgb:fffff/0/0\a",
          "\e]4;1;#ff0000\a",
          "\e]10;rgb:zz/00/00\a",
          "\e]11;rgb:00/00\a"
        ],
        do: assert(run(bad <> "k", colors()) |> Enum.map(&elem(&1, 0)) == [:key], inspect(bad))

    assert run("\e]4;1;rgb:ff/00/00\a", Parse.new()) == []
  end

  test "DA1 leaves the colour window open; the status reply ends it" do
    {items, t} = Parse.events("\e[?62c\e]10;rgb:ff/ff/ff\a\e[0n", colors())
    assert items == [{:reply, :fg, {255, 255, 255}}, {:reply, :colors_end, nil}]
    refute is_map_key(t.windows, :colors)
    assert run("\e[0n", Parse.new()) == []
  end

  test "colour scheme reports are parsed outside any window" do
    assert run("\e[?997;2n", Parse.new()) == [{:reply, :scheme, :light}]
    assert run("\e[?997;1n", Parse.new()) == [{:reply, :scheme, :dark}]
    assert run("\e[?997;3n", Parse.new()) == []
  end
end
