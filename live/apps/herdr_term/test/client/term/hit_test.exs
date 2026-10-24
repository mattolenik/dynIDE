defmodule HerdrTerm.Client.Term.HitTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Client.Term.Hit

  @tab %{rect: %{x: 10, y: 0, w: 8, h: 1}, path: [:tabs, {:tab, 1}], role: :tab, drag: false}
  @tabs %{rect: %{x: 0, y: 0, w: 80, h: 1}, path: [:tabs], role: :tabs, drag: false}
  @div %{rect: %{x: 40, y: 1, w: 1, h: 20}, path: [{:divider, []}], role: :divider, drag: true}
  @hits [@tab, @div, @tabs]

  defp m(kind, button, x, y),
    do: {:mouse, %{kind: kind, button: button, x: x, y: y, mods: [], px: nil}}

  defp route(ev, grab \\ nil, now \\ 1000, hits \\ @hits), do: Hit.route(hits, grab, ev, now)

  defp grabbed, do: elem(route(m(:press, :left, 40, 5)), 1)

  test "non-mouse events pass" do
    key = {:key, %{key: "a", mods: [], event: :press, text: "a"}}
    assert route(key) == {[key], nil}
    assert route({:paste, "x"}, grabbed()) == {[{:paste, "x"}], grabbed()}
  end

  test "events over no hit pass through unchanged" do
    for ev <- [m(:press, :left, 5, 5), m(:release, :left, 5, 5), m(:scroll, :wheel_up, 5, 5)],
        do: assert({[^ev], _} = route(ev))
  end

  test "topmost hit wins: press on a tab inside the tabs region clicks the tab" do
    assert {[{:chrome, [:tabs, {:tab, 1}], {:click, %{x: 12, y: 0}}}], _} =
             route(m(:press, :left, 12, 0))

    assert {[{:chrome, [:tabs], {:click, %{x: 30, y: 0}}}], _} = route(m(:press, :left, 30, 0))
  end

  test "right and middle press" do
    assert {[{:chrome, [:tabs, {:tab, 1}], {:right_click, %{x: 12, y: 0}}}], _} =
             route(m(:press, :right, 12, 0))

    assert {[{:chrome, [:tabs, {:tab, 1}], {:middle_click, %{x: 12, y: 0}}}], _} =
             route(m(:press, :middle, 12, 0))
  end

  test "wheel emits scroll_up / scroll_down" do
    assert {[{:chrome, [:tabs], {:scroll_up, %{x: 30, y: 0}}}], _} =
             route(m(:scroll, :wheel_up, 30, 0))

    assert {[{:chrome, [:tabs], {:scroll_down, %{x: 30, y: 0}}}], _} =
             route(m(:scroll, :wheel_down, 30, 0))
  end

  test "releases, moves and drags without a grab over a hit are swallowed" do
    for ev <- [m(:release, :left, 12, 0), m(:move, :none, 12, 0), m(:drag, :left, 12, 0)],
        do: assert({[], nil} = route(ev))
  end

  test "press on a drag hit grabs and emits nothing; drag and drop follow the grab" do
    assert {[], %{path: [{:divider, []}], at: 1000}} = route(m(:press, :left, 40, 5))
    g = grabbed()

    # the drag leaves the divider's rect: still the grab's path
    assert {[{:chrome, [{:divider, []}], {:drag, %{x: 50, y: 6}}}], ^g} =
             route(m(:drag, :left, 50, 6), g, 1010)

    assert {[{:chrome, [{:divider, []}], {:drop, %{x: 51, y: 6}}}], g2} =
             route(m(:release, :left, 51, 6), g, 1020)

    # the grab is cleared: a later drag over no hit passes through
    ev = m(:drag, :left, 5, 5)
    assert {[^ev], _} = route(ev, g2, 1030)
  end

  test "stale grab: a grab whose path is gone from the hits is dropped" do
    g = grabbed()
    hits = [@tab, @tabs]
    ev = m(:drag, :left, 50, 6)
    assert {[^ev], nil} = Hit.route(hits, g, ev, 1010)
    rel = m(:release, :left, 50, 6)
    assert {[^rel], nil} = Hit.route(hits, g, rel, 1010)
  end

  test "double click within 350 ms of a press on the same path" do
    {[{:chrome, _, {:click, _}}], g} = route(m(:press, :left, 12, 0), nil, 1000)
    {[], g} = route(m(:release, :left, 12, 0), g, 1100)

    assert {[{:chrome, [:tabs, {:tab, 1}], {:double_click, %{x: 12, y: 0}}}], _} =
             route(m(:press, :left, 12, 0), g, 1349)

    assert {[{:chrome, [:tabs, {:tab, 1}], {:click, %{x: 12, y: 0}}}], _} =
             route(m(:press, :left, 12, 0), g, 1351)
  end

  test "a press on another path is a plain click" do
    {_, g} = route(m(:press, :left, 12, 0), nil, 1000)

    assert {[{:chrome, [:tabs], {:click, _}}], _} = route(m(:press, :left, 30, 0), g, 1100)
  end

  test "double click on a drag hit emits double_click and does not grab" do
    {[], g} = route(m(:press, :left, 40, 5), nil, 1000)
    {[{:chrome, _, {:drop, _}}], g} = route(m(:release, :left, 40, 5), g, 1050)

    assert {[{:chrome, [{:divider, []}], {:double_click, %{x: 40, y: 5}}}], g} =
             route(m(:press, :left, 40, 5), g, 1200)

    assert {[], _} = route(m(:release, :left, 40, 5), g, 1250)
  end
end
