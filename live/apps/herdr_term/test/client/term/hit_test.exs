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

  test "a popup pane's box hides the hits under it and passes events through" do
    pop = %{rect: %{x: 35, y: 3, w: 10, h: 5}, path: [{:pane, 9}], role: :pane, drag: false}
    hits = [@tab, pop, @div, @tabs]
    press = m(:press, :left, 40, 5)
    assert route(press, nil, 1000, hits) == {[press], :pass}
    assert Hit.hover(hits, 40, 5) == nil
    # outside the box the divider still grabs
    assert {[], %{held: true}} = route(m(:press, :left, 40, 10), nil, 1000, hits)
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

  test "releases and drags without a grab over a hit are swallowed" do
    for ev <- [m(:release, :left, 12, 0), m(:drag, :left, 12, 0)],
        do: assert({[], nil} = route(ev))
  end

  test "a move over a hit passes through (the server clears a link hover)" do
    {:mouse, mm} = m(:move, :none, 12, 0)
    ev = {:mouse, %{mm | mods: [:ctrl]}}
    assert {[^ev], nil} = route(ev)
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

  test "stale grab: dropped; its drags and release are swallowed, not leaked to a pane" do
    g = grabbed()
    hits = [@tab, @tabs]
    {[], g} = Hit.route(hits, g, m(:drag, :left, 50, 6), 1010)
    {[], g} = Hit.route(hits, g, m(:release, :left, 50, 6), 1020)
    # after that release, events over no hit pass again
    ev = m(:drag, :left, 50, 6)
    assert {[^ev], _} = Hit.route(hits, g, ev, 1030)
  end

  # {event, emitted} steps from no grab; :same is the event itself
  defp walk(steps) do
    Enum.reduce(steps, {nil, 1000}, fn {ev, want}, {g, now} ->
      {out, g} = route(ev, g, now)
      assert out == if(want == :same, do: [ev], else: want), inspect({ev, g})
      {g, now + 400}
    end)
  end

  test "pass-through grab: a press over no hit keeps its drags and release unchanged" do
    # a pane selection dragged across the tab bar and the divider, released over a tab
    walk([
      {m(:press, :left, 5, 5), :same},
      {m(:drag, :left, 12, 0), :same},
      {m(:drag, :left, 40, 5), :same},
      {m(:release, :left, 12, 0), :same},
      # the release ended it: chrome is chrome again
      {m(:drag, :left, 12, 0), []},
      {m(:press, :left, 12, 0), [{:chrome, [:tabs, {:tab, 1}], {:click, %{x: 12, y: 0}}}]}
    ])
  end

  test "a press on a non-drag hit swallows its drags and release, even over a pane" do
    walk([
      {m(:press, :left, 12, 0), [{:chrome, [:tabs, {:tab, 1}], {:click, %{x: 12, y: 0}}}]},
      {m(:drag, :left, 5, 5), []},
      {m(:release, :left, 5, 5), []},
      # after the release, pane events pass again
      {m(:drag, :left, 5, 5), :same},
      {m(:release, :left, 5, 5), :same}
    ])
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

  test "a reorder hit (tab, drag: true) clicks on press; motion drags with over; a still release adds nothing" do
    t1 = %{@tab | drag: true}
    t2 = %{t1 | rect: %{x: 20, y: 0, w: 8, h: 1}, path: [:tabs, {:tab, 2}]}
    hits = [t1, t2, @div, @tabs]
    p1 = [:tabs, {:tab, 1}]

    assert {[{:chrome, ^p1, {:click, %{x: 12, y: 0}}}], g} =
             route(m(:press, :left, 12, 0), nil, 1000, hits)

    assert {[], g} = route(m(:release, :left, 12, 0), g, 1100, hits)

    assert {[{:chrome, ^p1, {:click, _}}], g} = route(m(:press, :left, 12, 0), g, 2000, hits)

    assert {[{:chrome, ^p1, {:drag, %{x: 22, y: 0, over: [:tabs, {:tab, 2}]}}}], g} =
             route(m(:drag, :left, 22, 0), g, 2100, hits)

    assert {[{:chrome, ^p1, {:drag, %{over: nil}}}], g} =
             route(m(:drag, :left, 60, 30), g, 2150, hits)

    assert {[{:chrome, ^p1, {:drop, %{x: 22, y: 0, over: [:tabs, {:tab, 2}]}}}], g} =
             route(m(:release, :left, 22, 0), g, 2200, hits)

    refute g.held

    # a divider drag still names no `over`
    assert {[{:chrome, [{:divider, []}], {:drag, at}}], _} =
             route(m(:drag, :left, 30, 5), grabbed(), 1000, hits)

    refute Map.has_key?(at, :over)
  end
end
