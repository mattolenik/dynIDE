defmodule HerdrServer.View.Frame do
  @moduledoc """
  Screen regions for a size, with herdr's desktop layout (pure):

    * `status`: the last row, full width.
    * `sidebar`: x 0, y 0, the height above the status row; `4` columns collapsed, else
      `width` clamped to `min..max`, capped at `cols - 1`. Nil when not visible, when the
      terminal is narrower than that width plus 20 (narrow terminals drop it) or when
      there is no row above the status.
    * `tabs`: row 0 of the main area (right of the sidebar), or its last row above the
      status row when `ui.tab_bar.position` is `:bottom`; nil below 3 rows, and nil when
      `ui.tab_bar.hide_single` is set and `tabs_count` is 1.
    * `panes`: the rest of the main area. Width and height are clamped to >= 0, so at 1x1
      it may be empty; every rect lies inside the size.
  """

  @min_main 20
  @collapsed 4

  @type rect :: HerdrScene.Scene.rect()
  @type t :: %{sidebar: rect | nil, tabs: rect | nil, status: rect, panes: rect}

  @spec regions(%{cols: pos_integer, rows: pos_integer}, HerdrServer.App.Ui.t(), pos_integer) ::
          t
  def regions(%{cols: cols, rows: rows}, ui, tabs_count \\ 2) do
    main_h = max(rows - 1, 0)
    sidebar = sidebar(ui.sidebar, cols, main_h)
    sw = if sidebar, do: sidebar.w, else: 0
    main_w = max(cols - sw, 0)
    {tabs, panes} = main(ui.tab_bar, tabs_count, %{x: sw, w: main_w, h: main_h}, rows)

    %{
      sidebar: sidebar,
      tabs: tabs,
      status: %{x: 0, y: main_h, w: cols, h: min(rows, 1)},
      panes: panes
    }
  end

  defp main(bar, tabs_count, %{x: x, w: w, h: h}, rows) do
    bottom = Map.get(bar, :position) == :bottom

    if rows >= 3 and not (Map.get(bar, :hide_single, false) and tabs_count == 1) do
      {%{x: x, y: if(bottom, do: h - 1, else: 0), w: w, h: 1},
       %{x: x, y: if(bottom, do: 0, else: 1), w: w, h: max(h - 1, 0)}}
    else
      {nil, %{x: x, y: 0, w: w, h: h}}
    end
  end

  defp sidebar(%{visible: true} = s, cols, main_h) when main_h > 0 do
    w = if s.collapsed, do: @collapsed, else: s.width |> max(s.min) |> min(s.max)
    if cols >= w + @min_main, do: %{x: 0, y: 0, w: min(w, cols - 1), h: main_h}
  end

  defp sidebar(_hidden, _cols, _main_h), do: nil
end
