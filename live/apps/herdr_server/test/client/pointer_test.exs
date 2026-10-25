defmodule HerdrServer.Client.PointerTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Event}
  alias HerdrServer.Client.{Pointer, Selection}

  # pane 1: 20x5 at (0, 1); pane 2: 20x5 at (21, 1)
  @r1 %{x: 0, y: 1, w: 20, h: 5}
  @r2 %{x: 21, y: 1, w: 20, h: 5}
  @flat %{total: 5, viewport: 5, offset: 0}

  defp rows(lines) do
    lines
    |> Enum.map(fn text ->
      gs = String.graphemes(text)

      (gs ++ List.duplicate("", 20 - length(gs)))
      |> Enum.map(&%Cell{glyph: if(&1 == " ", do: "", else: &1)})
      |> Cell.encode_row()
    end)
    |> List.to_tuple()
  end

  defp link_rows, do: rows(["go https://e.com/x n", "", "", "", ""])

  defp info(opts) do
    Map.merge(
      %{
        tracking: false,
        any_motion: false,
        alt_screen: false,
        alternate_scroll: false,
        scroll: @flat,
        rows: rows(["hello world foo", "second line", "", "", ""])
      },
      Map.new(opts)
    )
  end

  defp ctx(opts \\ []) do
    %{
      panes: [%{id: 1, rect: @r1}, %{id: 2, rect: @r2}],
      focused: Keyword.get(opts, :focused, 1),
      info: %{1 => info(Keyword.get(opts, :p1, [])), 2 => info(Keyword.get(opts, :p2, []))},
      now_ms: Keyword.get(opts, :now, 1000),
      scroll_lines: 3,
      copy_on_select: Keyword.get(opts, :copy_on_select, true)
    }
  end

  defp m(kind, button, x, y, mods \\ []),
    do: {:mouse, %{kind: kind, button: button, x: x, y: y, mods: mods, px: nil}}

  defp run(p, events, c) do
    Enum.reduce(events, {p, []}, fn ev, {p, _} -> Pointer.resolve(p, ev, c) end)
  end

  describe "wheel" do
    test "tracking child: forwarded; an unfocused pane is focused first" do
      ev = m(:scroll, :wheel_up, 3, 2)
      assert {_, [{:forward, ^ev}]} = Pointer.resolve(%Pointer{}, ev, ctx(p1: [tracking: true]))
      ev2 = m(:scroll, :wheel_up, 23, 2)

      assert {_, [{:focus, 2}, {:forward, ^ev2}]} =
               Pointer.resolve(%Pointer{}, ev2, ctx(p2: [tracking: true]))
    end

    test "alternate screen with alternate scroll: one arrow per notch" do
      c = ctx(p1: [alt_screen: true, alternate_scroll: true])
      up = Event.key(:up)
      down = Event.key(:down)

      assert {_, [{:keys, 1, [^up]}]} =
               Pointer.resolve(%Pointer{}, m(:scroll, :wheel_up, 3, 2), c)

      assert {_, [{:keys, 1, [^down]}]} =
               Pointer.resolve(%Pointer{}, m(:scroll, :wheel_down, 3, 2), c)
    end

    test "otherwise host scroll by scroll_lines; unfocused pane focused first" do
      assert {_, [{:scroll, 1, -3}]} =
               Pointer.resolve(%Pointer{}, m(:scroll, :wheel_up, 3, 2), ctx())

      assert {_, [{:focus, 2}, {:scroll, 2, 3}]} =
               Pointer.resolve(%Pointer{}, m(:scroll, :wheel_down, 23, 2), ctx())
    end

    test "horizontal wheel only forwarded when tracking" do
      ev = m(:scroll, :wheel_left, 3, 2)
      assert {_, []} = Pointer.resolve(%Pointer{}, ev, ctx())
      assert {_, [{:forward, ^ev}]} = Pointer.resolve(%Pointer{}, ev, ctx(p1: [tracking: true]))
    end

    test "wheel during a drag scrolls the selection pane and extends the selection" do
      c = ctx(p1: [scroll: %{total: 25, viewport: 5, offset: 20}])
      {p, _} = run(%Pointer{}, [m(:press, :left, 2, 3), m(:drag, :left, 5, 3)], c)
      assert p.selection.head == {5, 22}
      {p, actions} = Pointer.resolve(p, m(:scroll, :wheel_up, 5, 3), c)
      assert {:scroll, 1, -3} in actions
      assert p.selection.anchor == {2, 22}
      assert p.selection.head == {5, 19}
    end
  end

  describe "selection" do
    test "drag makes a char selection, clamped to the pane; release copies and clears" do
      {p, []} = Pointer.resolve(%Pointer{}, m(:press, :left, 2, 2), ctx())
      assert p.selection == nil and p.press != nil
      {p, actions} = Pointer.resolve(p, m(:drag, :left, 30, 3), ctx())

      assert %Selection{pane: 1, anchor: {2, 1}, head: {19, 2}, unit: :char, shown: true} =
               p.selection

      assert :repaint in actions
      {p, actions} = Pointer.resolve(p, m(:release, :left, 30, 3), ctx())
      assert {:copy, 1, {2, 1}, {19, 2}} in actions
      assert p.selection == nil and p.press == nil
    end

    test "copy_on_select false keeps the selection and copies nothing" do
      c = ctx(copy_on_select: false)

      {p, actions} =
        run(
          %Pointer{},
          [m(:press, :left, 2, 2), m(:drag, :left, 5, 2), m(:release, :left, 5, 2)],
          c
        )

      refute Enum.any?(actions, &match?({:copy, _, _, _}, &1))
      assert %Selection{shown: true} = p.selection
    end

    test "release without movement is a click; a press clears an existing selection" do
      {p, _} = run(%Pointer{}, [m(:press, :left, 2, 2), m(:drag, :left, 5, 2)], ctx())
      {p, _} = Pointer.resolve(p, m(:release, :left, 5, 2), ctx(copy_on_select: false))
      assert p.selection != nil
      {p, actions} = Pointer.resolve(p, m(:press, :left, 8, 3), ctx())
      assert p.selection == nil and :repaint in actions
      {p, actions} = Pointer.resolve(p, m(:release, :left, 8, 3), ctx())
      assert actions == [] and p.selection == nil
      assert %{pane: 1, x: 8, row: 2} = p.last_click
    end

    test "a press on an unfocused pane focuses it" do
      assert {_, [{:focus, 2}]} = Pointer.resolve(%Pointer{}, m(:press, :left, 23, 2), ctx())
    end

    test "double click selects a word, copies, keeps it 500 ms" do
      {p, _} = run(%Pointer{}, [m(:press, :left, 7, 1), m(:release, :left, 7, 1)], ctx(now: 1000))
      {p, actions} = Pointer.resolve(p, m(:press, :left, 8, 1), ctx(now: 1300))
      assert %Selection{anchor: {6, 0}, head: {10, 0}, unit: :word, shown: true} = p.selection
      assert :repaint in actions
      {p, actions} = Pointer.resolve(p, m(:release, :left, 8, 1), ctx(now: 1350))
      assert {:copy, 1, {6, 0}, {10, 0}} in actions
      assert {:expire_selection, 500} in actions
      assert p.selection != nil
    end

    test "a second click after 350 ms or more than a cell away is a plain press" do
      {p, _} = run(%Pointer{}, [m(:press, :left, 7, 1), m(:release, :left, 7, 1)], ctx(now: 1000))
      {q, _} = Pointer.resolve(p, m(:press, :left, 7, 1), ctx(now: 1351))
      assert q.selection == nil
      {q, _} = Pointer.resolve(p, m(:press, :left, 9, 1), ctx(now: 1100))
      assert q.selection == nil
    end

    test "dragging after a double click extends by words and copies and clears" do
      events = [m(:press, :left, 7, 1), m(:release, :left, 7, 1)]
      {p, _} = run(%Pointer{}, events, ctx(now: 1000))
      {p, _} = Pointer.resolve(p, m(:press, :left, 7, 1), ctx(now: 1200))
      {p, _} = Pointer.resolve(p, m(:drag, :left, 13, 1), ctx(now: 1250))
      assert Selection.range(p.selection) == {{6, 0}, {14, 0}}
      {p, _} = Pointer.resolve(p, m(:drag, :left, 1, 1), ctx(now: 1260))
      assert Selection.range(p.selection) == {{0, 0}, {10, 0}}
      {p, actions} = Pointer.resolve(p, m(:release, :left, 1, 1), ctx(now: 1300))
      assert {:copy, 1, {0, 0}, {10, 0}} in actions
      refute {:expire_selection, 500} in actions
      assert p.selection == nil
    end

    test "autoscroll on the edge rows, a jump beyond them, stop back inside" do
      c = ctx(p1: [scroll: %{total: 25, viewport: 5, offset: 20}])
      {p, _} = Pointer.resolve(%Pointer{}, m(:press, :left, 2, 3), c)
      {p, actions} = Pointer.resolve(p, m(:drag, :left, 2, 1), c)
      assert {:autoscroll, 1, :up} in actions
      assert p.autoscroll == %{pane: 1, dir: :up}

      {p, actions} = Pointer.resolve(p, m(:drag, :left, 2, 3), c)
      assert :autoscroll_stop in actions and p.autoscroll == nil

      # two rows below the pane: jump clamp(3 * 2, 3, 15) = 6 lines
      c2 = ctx(p1: [scroll: %{total: 25, viewport: 5, offset: 10}])
      {p, actions} = Pointer.resolve(p, m(:drag, :left, 2, 7), c2)
      assert {:scroll, 1, 6} in actions and {:autoscroll, 1, :down} in actions
      assert p.selection.head == {2, 20}

      # one row above the top: jump 3
      {_, actions} = Pointer.resolve(p, m(:drag, :left, 2, 0), c2)
      assert {:scroll, 1, -3} in actions and {:autoscroll, 1, :up} in actions
    end

    test "tick scrolls one line and extends; without autoscroll it stops" do
      c = ctx(p1: [scroll: %{total: 25, viewport: 5, offset: 20}])
      {p, _} = run(%Pointer{}, [m(:press, :left, 2, 3), m(:drag, :left, 4, 1)], c)
      {p, actions} = Pointer.tick(p, c)
      assert actions == [{:scroll, 1, -1}, :repaint]
      assert p.selection.head == {4, 19}
      assert {_, [:autoscroll_stop]} = Pointer.tick(%Pointer{}, c)

      # at the end of the history the ticking stops
      top = ctx(p1: [scroll: %{total: 25, viewport: 5, offset: 0}])
      assert {%{autoscroll: nil}, [:autoscroll_stop]} = Pointer.tick(p, top)
    end
  end

  describe "scrollbar" do
    # total 100, viewport 5, offset 50 of max 95: thumb length 1 at row round(50*4/95) = 2
    @scrolled [scroll: %{total: 100, viewport: 5, offset: 50}]

    test "a drag on the thumb keeps the grab offset" do
      c = ctx(p1: @scrolled)
      {p, []} = Pointer.resolve(%Pointer{}, m(:press, :left, 19, 3), c)
      assert %{kind: :scrollbar, pane: 1, grab: 0} = p.drag
      {p, [{:scroll_top, 1, 95}]} = Pointer.resolve(p, m(:drag, :left, 19, 5), c)
      {p, []} = Pointer.resolve(p, m(:release, :left, 19, 5), c)
      assert p.drag == nil and p.selection == nil
    end

    test "a press on the track centres the thumb on the row" do
      assert {_, [{:scroll_top, 1, 0}]} =
               Pointer.resolve(%Pointer{}, m(:press, :left, 19, 1), ctx(p1: @scrolled))
    end

    test "the rightmost column of an unscrolled pane is content" do
      {p, []} = Pointer.resolve(%Pointer{}, m(:press, :left, 19, 1), ctx())
      assert p.drag == nil and p.press != nil
    end
  end

  describe "links and hover" do
    test "ctrl press on a link opens it and swallows until the release" do
      c = ctx(p1: [rows: link_rows()])
      {p, actions} = Pointer.resolve(%Pointer{}, m(:press, :left, 5, 1, [:ctrl]), c)
      assert actions == [{:open, 1, %{url: "https://e.com/x", mods: [:ctrl]}}]
      assert {p, []} = Pointer.resolve(p, m(:drag, :left, 6, 1, [:ctrl]), c)
      assert {p, []} = Pointer.resolve(p, m(:release, :left, 6, 1, [:ctrl]), c)
      assert p.swallow_up == nil and p.selection == nil
    end

    test "an osc 8 link opens by id and position" do
      cells =
        for i <- 0..19,
            do: %Cell{glyph: if(i < 4, do: "l", else: ""), link: if(i < 4, do: 9, else: 0)}

      r = List.to_tuple([Cell.encode_row(cells) | Tuple.to_list(rows(["", "", "", ""]))])
      c = ctx(p1: [rows: r])

      assert {_, [{:open, 1, %{id: 9, x: 2, y: 0}}]} =
               Pointer.resolve(%Pointer{}, m(:press, :left, 2, 1, [:ctrl]), c)
    end

    test "ctrl move over a link hovers; any other event clears it" do
      c = ctx(p1: [rows: link_rows()])
      {p, actions} = Pointer.resolve(%Pointer{}, m(:move, :none, 5, 1, [:ctrl]), c)
      assert %{pane: 1, id: 0, url: "https://e.com/x", from: {3, 0}, to: {17, 0}} = p.hover
      assert :repaint in actions
      {p, [:repaint]} = Pointer.resolve(p, m(:move, :none, 6, 1), c)
      assert p.hover == nil
    end

    test "a ctrl move off the link, or outside every pane, clears the hover" do
      c = ctx(p1: [rows: link_rows()])
      {p, _} = Pointer.resolve(%Pointer{}, m(:move, :none, 5, 1, [:ctrl]), c)
      assert p.hover != nil
      {q, actions} = Pointer.resolve(p, m(:move, :none, 1, 1, [:ctrl]), c)
      assert q.hover == nil and :repaint in actions
      {q, actions} = Pointer.resolve(p, m(:move, :none, 20, 0, [:ctrl]), c)
      assert q.hover == nil and :repaint in actions
    end

    test "plain moves over a non any-motion pane reach nothing" do
      assert {_, []} = Pointer.resolve(%Pointer{}, m(:move, :none, 5, 1), ctx())

      assert {_, []} =
               Pointer.resolve(%Pointer{}, m(:move, :none, 5, 1), ctx(p1: [tracking: true]))

      ev = m(:move, :none, 5, 1)

      assert {_, [{:forward, ^ev}]} =
               Pointer.resolve(%Pointer{}, ev, ctx(p1: [tracking: true, any_motion: true]))
    end
  end

  test "tracking_child_test: press, drag and wheel forward; ctrl press on a link opens" do
    c = ctx(p1: [tracking: true, rows: rows(["go https://e.com/x n", "", "", "", ""])])

    {p, _} =
      for ev <- [m(:press, :left, 2, 2), m(:drag, :left, 4, 2), m(:release, :left, 4, 2)],
          reduce: {%Pointer{}, []} do
        {p, _} ->
          {p, actions} = Pointer.resolve(p, ev, c)
          assert actions == [{:forward, ev}]
          {p, actions}
      end

    assert p.selection == nil and p.press == nil
    wheel = m(:scroll, :wheel_down, 2, 2)
    assert {_, [{:forward, ^wheel}]} = Pointer.resolve(p, wheel, c)

    assert {_, [{:open, 1, %{url: "https://e.com/x"}}]} =
             Pointer.resolve(p, m(:press, :left, 5, 1, [:ctrl]), c)
  end

  test "events outside every pane are forwarded" do
    ev = m(:press, :left, 20, 0)
    assert {_, [{:forward, ^ev}]} = Pointer.resolve(%Pointer{}, ev, ctx())
  end

  describe "facts and focus" do
    test "an alternate screen toggle clears the selection and hover; a scroll only the hover" do
      {p, _} = run(%Pointer{}, [m(:press, :left, 2, 2), m(:drag, :left, 5, 2)], ctx())
      assert p.alt == {1, false}
      assert Pointer.facts(p, 1, %{alt_screen: false, offset: 7}).selection != nil
      assert Pointer.facts(p, 2, %{alt_screen: true}) == p
      assert %Pointer{selection: nil, press: nil} = Pointer.facts(p, 1, %{alt_screen: true})

      {h, _} =
        Pointer.resolve(%Pointer{}, m(:move, :none, 5, 1, [:ctrl]), ctx(p1: [rows: link_rows()]))

      assert %{offset: 0} = h.hover
      assert Pointer.facts(h, 1, %{alt_screen: false, offset: 0}) == h
      assert Pointer.facts(h, 1, %{alt_screen: false, offset: 3}).hover == nil
      assert Pointer.facts(h, 1, %{alt_screen: true}).hover == nil
    end

    test "focus moving to another pane clears the selection and hover" do
      {p, _} = run(%Pointer{}, [m(:press, :left, 2, 2), m(:drag, :left, 5, 2)], ctx())
      assert Pointer.focus_moved(p, 1, 1) == p
      assert Pointer.focus_moved(p, 2, 1) == p
      assert %Pointer{selection: nil, press: nil} = Pointer.focus_moved(p, 1, 2)
    end
  end

  test "wheel-extending a word selection reads words only inside the fetched rows" do
    # rows fetched at offset 20 of 25: their row 0 is absolute row 20
    c = ctx(p1: [scroll: %{total: 25, viewport: 5, offset: 20}])
    events = [m(:press, :left, 7, 1), m(:release, :left, 7, 1)]
    {p, _} = run(%Pointer{}, events, %{c | now_ms: 1000})
    {p, _} = Pointer.resolve(p, m(:press, :left, 7, 1), %{c | now_ms: 1100})
    assert Selection.range(p.selection) == {{6, 20}, {10, 20}}
    # up 3 to offset 17: pointer row 0 is absolute 17, above the fetched rows: a cell
    {q, _} = Pointer.resolve(p, m(:scroll, :wheel_up, 13, 1), c)
    assert Selection.range(q.selection) == {{13, 17}, {10, 20}}
    # pointer row 4 is absolute 21, fetched row 1 ("second line"): the word "line"
    {q, _} = Pointer.resolve(p, m(:scroll, :wheel_up, 9, 5), c)
    assert Selection.range(q.selection) == {{6, 20}, {10, 21}}
  end

  describe "prune" do
    test "drops state for a pane that left the scene or changed size" do
      {p, _} = run(%Pointer{}, [m(:press, :left, 2, 2), m(:drag, :left, 5, 2)], ctx())
      scene = %{panes: [%{id: 1, rect: @r1}]}
      assert Pointer.prune(p, scene, scene) == p
      assert %Pointer{selection: nil, press: nil} = Pointer.prune(p, scene, %{panes: []})
      resized = %{panes: [%{id: 1, rect: %{@r1 | w: 30}}]}
      assert %Pointer{selection: nil} = Pointer.prune(p, scene, resized)
      moved = %{panes: [%{id: 1, rect: %{@r1 | x: 4}}]}
      assert Pointer.prune(p, scene, moved) == p
    end
  end
end
