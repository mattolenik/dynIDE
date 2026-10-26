defmodule DynideServer.Client.SelectionTest do
  use ExUnit.Case, async: true
  alias DynideScene.Scene.Overlay
  alias DynideServer.Client.Selection

  defp sel(a, h, opts \\ []),
    do: struct(Selection, [pane: 1, anchor: a, head: h, shown: true] ++ opts)

  defp scroll(offset), do: %{total: 100, viewport: 10, offset: offset}
  defp ov(from, to), do: %Overlay{kind: :selection, args: %{from: from, to: to}}

  test "defaults" do
    assert %Selection{pane: nil, anchor: nil, head: nil, unit: :char, shown: false} = %Selection{}
  end

  test "range orders anchor and head" do
    assert Selection.range(sel({5, 3}, {2, 1})) == {{2, 1}, {5, 3}}
    assert Selection.range(sel({2, 1}, {5, 3})) == {{2, 1}, {5, 3}}
    assert Selection.range(sel({5, 1}, {2, 1})) == {{2, 1}, {5, 1}}
  end

  test "range/2 widens line selections to full rows" do
    assert Selection.range(sel({5, 3}, {2, 1}, unit: :line), 20) == {{0, 1}, {19, 3}}
    assert Selection.range(sel({5, 3}, {2, 1}), 20) == {{2, 1}, {5, 3}}
  end

  test "overlay maps absolute rows to viewport rows" do
    assert Selection.overlay(sel({1, 52}, {4, 55}), scroll(50), 20, 10) == ov({1, 2}, {4, 5})
    assert Selection.overlay(sel({4, 55}, {1, 52}), scroll(50), 20, 10) == ov({1, 2}, {4, 5})
  end

  test "overlay clips to the viewport" do
    assert Selection.overlay(sel({3, 40}, {4, 55}), scroll(50), 20, 10) == ov({0, 0}, {4, 5})
    assert Selection.overlay(sel({3, 52}, {4, 90}), scroll(50), 20, 10) == ov({3, 2}, {19, 9})
    assert Selection.overlay(sel({3, 40}, {4, 90}), scroll(50), 20, 10) == ov({0, 0}, {19, 9})
  end

  test "overlay is nil outside the viewport or when hidden" do
    assert Selection.overlay(sel({0, 10}, {4, 49}), scroll(50), 20, 10) == nil
    assert Selection.overlay(sel({0, 60}, {4, 70}), scroll(50), 20, 10) == nil
    assert Selection.overlay(sel({0, 52}, {4, 55}, shown: false), scroll(50), 20, 10) == nil
    assert Selection.overlay(nil, scroll(50), 20, 10) == nil
  end

  test "line unit spans the full width; word unit is like char" do
    assert Selection.overlay(sel({5, 52}, {2, 53}, unit: :line), scroll(50), 20, 10) ==
             ov({0, 2}, {19, 3})

    assert Selection.overlay(sel({5, 52}, {2, 53}, unit: :word), scroll(50), 20, 10) ==
             ov({5, 2}, {2, 3})
  end
end
