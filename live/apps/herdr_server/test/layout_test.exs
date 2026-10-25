defmodule HerdrServer.LayoutTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Layout

  defp r(x, y, w, h), do: %{x: x, y: y, w: w, h: h}

  defp from_tree(root, focus), do: %Layout{root: root, focus: focus}

  # 1 | (2 over 3), the "L" shape
  defp l_shape do
    from_tree(
      {:split, :horizontal, 0.5, {:pane, 1}, {:split, :vertical, 0.5, {:pane, 2}, {:pane, 3}}},
      1
    )
  end

  test "split paths preserve preorder geometry and resize targets" do
    tree =
      {:split, :horizontal, 0.5, {:split, :vertical, 0.5, {:pane, 1}, {:pane, 2}},
       {:split, :vertical, 0.25, {:pane, 3}, {:pane, 4}}}

    l = from_tree(tree, 1)
    area = r(3, 7, 120, 80)
    splits = Layout.splits(l, area)

    assert Enum.map(splits, &{&1.path, &1.direction, &1.pos, &1.area}) == [
             {[], :horizontal, 63, area},
             {[false], :vertical, 47, r(3, 7, 60, 80)},
             {[true], :vertical, 27, r(63, 7, 60, 80)}
           ]

    resized = Layout.splits(Layout.set_ratio(l, [true], 0.5), area)
    assert Enum.at(resized, 1).pos == 47
    assert Enum.at(resized, 2).pos == 47
  end

  test "pane_ids, count, panes, focus" do
    l = l_shape()
    assert Layout.pane_ids(l) == [1, 2, 3]
    assert Layout.count(l) == 3

    assert Layout.panes(l, r(0, 0, 100, 40)) == [
             %{id: 1, rect: r(0, 0, 50, 40), focused: true},
             %{id: 2, rect: r(50, 0, 50, 20), focused: false},
             %{id: 3, rect: r(50, 20, 50, 20), focused: false}
           ]

    assert %{focus: 3, prev_focus: 1} = Layout.focus(l, 3)
    assert Layout.focus(l, 99) == l
  end

  test "split puts the new pane second and focuses it; clamps ratio" do
    l = Layout.new(1) |> Layout.split(1, :horizontal, 2, 0.95)
    assert l.root == {:split, :horizontal, 0.9, {:pane, 1}, {:pane, 2}}
    assert %{focus: 2, prev_focus: 1} = l
    assert Layout.split(l, 99, :vertical, 3) == l
  end

  test "find_in_direction on an L shape" do
    l = l_shape()
    a = r(0, 0, 100, 40)
    f = &Layout.find_in_direction(l, a, &1, &2)

    assert f.(1, :right) == 2
    assert f.(1, :left) == nil
    assert f.(1, :up) == nil
    assert f.(1, :down) == nil
    assert f.(2, :left) == 1
    assert f.(2, :down) == 3
    assert f.(2, :up) == nil
    assert f.(2, :right) == nil
    assert f.(3, :left) == 1
    assert f.(3, :up) == 2
    assert f.(3, :down) == nil
    assert f.(3, :right) == nil
  end

  test "find_in_direction tiebreaks by overlap" do
    # left pane spans full height; right column is 3 stacked: pick the one overlapping most
    l =
      from_tree(
        {:split, :horizontal, 0.5, {:pane, 1}, {:split, :vertical, 0.2, {:pane, 2}, {:pane, 3}}},
        1
      )

    assert Layout.find_in_direction(l, r(0, 0, 100, 50), 1, :right) == 3
  end

  test "close focused returns to previous focus, else the next pane" do
    l = l_shape() |> Layout.focus(3) |> Layout.focus(2)
    assert {:ok, c} = Layout.close(l, 2)
    assert c.focus == 3 and c.prev_focus == nil and Layout.pane_ids(c) == [1, 3]

    assert {:ok, c} =
             Layout.close(Layout.new(1) |> Layout.split(1, :horizontal, 2) |> Layout.focus(1), 1)

    assert c.root == {:pane, 2} and c.focus == 2
  end

  test "close unfocused keeps focus and clears stale prev_focus" do
    l = l_shape() |> Layout.focus(3)
    assert {:ok, c} = Layout.close(l, 1)
    assert c.focus == 3 and c.prev_focus == nil
  end

  test "close last pane" do
    assert Layout.close(Layout.new(1), 1) == :last
  end

  test "resize left on the right pane of a 50/50 split" do
    l = Layout.new(1) |> Layout.split(1, :horizontal, 2)

    assert %{root: {:split, :horizontal, ratio, _, _}} =
             Layout.resize(l, r(0, 0, 100, 24), :left, 0.1)

    assert_in_delta ratio, 0.4, 1.0e-9
  end

  test "resize falls back to the opposite edge and clamps" do
    l = Layout.new(1) |> Layout.split(1, :horizontal, 2) |> Layout.focus(1)
    assert %{root: {:split, _, ratio, _, _}} = Layout.resize(l, r(0, 0, 100, 24), :right, 0.1)
    assert_in_delta ratio, 0.6, 1.0e-9
    assert %{root: {:split, _, 0.9, _, _}} = Layout.resize(l, r(0, 0, 100, 24), :right, 5.0)
    assert Layout.resize(l, r(0, 0, 100, 24), :up, 0.1) == l
  end

  test "swap exchanges leaves, keeps focus and shape" do
    l = l_shape()
    s = Layout.swap(l, 1, 3)
    assert Layout.pane_ids(s) == [3, 2, 1]
    assert s.focus == 1
    assert Layout.swap(l, 1, 1) == l
    assert Layout.swap(l, 1, 99) == l
  end

  test "borders" do
    one = Layout.new(1)
    a = r(0, 0, 100, 24)
    assert Layout.borders(Layout.panes(one, a), a, :auto) == [%{id: 1, rect: a, border: nil}]

    two = Layout.new(1) |> Layout.split(1, :horizontal, 2)
    [left, right] = Layout.borders(Layout.panes(two, a), a, :auto)
    assert left.rect == r(1, 1, 48, 22)

    assert left.border == %{
             rect: r(0, 0, 50, 24),
             edges: [:top, :bottom, :left, :right],
             title: nil
           }

    assert right.rect == r(51, 1, 48, 22)

    tiny = [%{id: 1, rect: r(0, 0, 1, 1)}, %{id: 2, rect: r(1, 0, 1, 1)}]
    assert [%{rect: %{w: 0, h: 0}} | _] = Layout.borders(tiny, a, :auto)
  end

  defp opts(zoom, borders), do: %{zoom: zoom, borders: borders}

  test "rects: a zoomed pane gets the whole area, an unknown zoom id is ignored" do
    a = r(0, 0, 100, 40)
    assert Layout.rects(l_shape(), a, opts(2, :auto)) == [%{id: 2, rect: a, border: nil}]

    assert Layout.rects(l_shape(), a, opts(99, :auto)) ==
             Layout.rects(l_shape(), a, opts(nil, :auto))

    assert Layout.size(l_shape(), a, opts(2, :auto), 2) == %{cols: 100, rows: 40}
    # a pane the zoom hides keeps its unzoomed tile size
    assert Layout.size(l_shape(), a, opts(2, :auto), 1) == %{cols: 48, rows: 38}
    assert Layout.size(l_shape(), a, opts(2, :auto), 99) == nil
  end

  test "rects: :off tiles the area with no borders, :always borders a single pane" do
    a = r(0, 0, 100, 40)
    off = Layout.rects(l_shape(), a, opts(nil, :off))
    assert Enum.all?(off, &(&1.border == nil))
    assert Enum.map(off, & &1.rect) == Enum.map(Layout.panes(l_shape(), a), & &1.rect)
    assert off |> Enum.map(&(&1.rect.w * &1.rect.h)) |> Enum.sum() == 100 * 40

    assert [%{rect: %{x: 1, y: 1, w: 98, h: 38}, border: %{rect: ^a}}] =
             Layout.rects(Layout.new(1), a, opts(nil, :always))

    assert [%{border: nil}] = Layout.rects(Layout.new(1), a, opts(nil, :auto))
  end
end
