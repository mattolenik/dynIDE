defmodule DynideServer.View.FrameTest do
  use ExUnit.Case, async: true

  alias DynideServer.App.Ui
  alias DynideServer.View.Frame

  test "herdr's desktop layout at 120x40" do
    assert Frame.regions(%{cols: 120, rows: 40}, %Ui{}) == %{
             sidebar: %{x: 0, y: 0, w: 26, h: 39},
             tabs: %{x: 26, y: 0, w: 94, h: 1},
             status: %{x: 0, y: 39, w: 120, h: 1},
             panes: %{x: 26, y: 1, w: 94, h: 38}
           }
  end

  test "collapsed, clamped, hidden and narrow sidebars" do
    ui = %Ui{}
    collapsed = %{ui | sidebar: %{ui.sidebar | collapsed: true}}
    r = Frame.regions(%{cols: 120, rows: 40}, collapsed)
    assert r.sidebar == %{x: 0, y: 0, w: 4, h: 39}
    assert r.panes == %{x: 4, y: 1, w: 116, h: 38}

    wide = %{ui | sidebar: %{ui.sidebar | width: 99}}
    assert Frame.regions(%{cols: 120, rows: 40}, wide).sidebar.w == 36

    hidden = %{ui | sidebar: %{ui.sidebar | visible: false}}

    assert %{sidebar: nil, panes: %{x: 0, y: 1, w: 120}} =
             Frame.regions(%{cols: 120, rows: 40}, hidden)

    assert %{sidebar: nil, tabs: %{x: 0, w: 40}} = Frame.regions(%{cols: 40, rows: 40}, ui)
  end

  test "no tab bar below 3 rows" do
    assert %{tabs: nil, panes: %{y: 0, h: 1}} = Frame.regions(%{cols: 80, rows: 2}, %Ui{})
  end

  test "hide_single drops the tab bar for one tab only" do
    ui = %Ui{tab_bar: %{position: :top, hide_single: true}}
    size = %{cols: 120, rows: 40}
    assert %{tabs: nil, panes: %{y: 0, h: 39}} = Frame.regions(size, ui, 1)
    assert %{tabs: %{y: 0}, panes: %{y: 1, h: 38}} = Frame.regions(size, ui, 2)
  end

  test "bottom puts the tab bar above the status row" do
    ui = %Ui{tab_bar: %{position: :bottom, hide_single: false}}

    assert %{tabs: %{y: 38, h: 1}, panes: %{y: 0, h: 38}} =
             Frame.regions(%{cols: 120, rows: 40}, ui)
  end

  test "every rect stays inside the size" do
    for c <- 1..30, r <- 1..8, ui <- [%Ui{}, %Ui{sidebar: %{%Ui{}.sidebar | collapsed: true}}] do
      regions = Frame.regions(%{cols: c, rows: r}, ui)
      assert regions.status == %{x: 0, y: r - 1, w: c, h: 1}

      for {name, rect} <- regions, rect != nil do
        assert rect.x >= 0 and rect.y >= 0 and rect.w >= 0 and rect.h >= 0, "#{name} #{c}x#{r}"
        assert rect.x + rect.w <= c and rect.y + rect.h <= r, "#{name} #{c}x#{r}"
      end
    end
  end
end
