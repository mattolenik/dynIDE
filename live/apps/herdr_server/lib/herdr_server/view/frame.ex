defmodule HerdrServer.View.Frame do
  @moduledoc """
  Screen regions for a size, with herdr's desktop layout (pure):

    * `status`: the last row, full width.
    * `sidebar`: x 0, y 0, the height above the status row; `4` columns collapsed, else
      `width` clamped to `min..max`, capped at `cols - 1`. Nil when not visible, when the
      terminal is narrower than that width plus 20 (narrow terminals drop it) or when
      there is no row above the status.
    * `tabs`: row 0 of the main area (right of the sidebar); nil below 3 rows.
    * `panes`: the rest of the main area. Width and height are clamped to >= 0, so at 1x1
      it may be empty; every rect lies inside the size.
  """

  @min_main 20
  @collapsed 4

  @type rect :: HerdrScene.Scene.rect()
  @type t :: %{sidebar: rect | nil, tabs: rect | nil, status: rect, panes: rect}

  @spec regions(%{cols: pos_integer, rows: pos_integer}, HerdrServer.App.Ui.t()) :: t
  def regions(%{cols: cols, rows: rows}, ui) do
    main_h = max(rows - 1, 0)
    sidebar = sidebar(ui.sidebar, cols, main_h)
    sw = if sidebar, do: sidebar.w, else: 0
    main_w = max(cols - sw, 0)
    tabs = if rows >= 3, do: %{x: sw, y: 0, w: main_w, h: 1}
    top = if tabs, do: 1, else: 0

    %{
      sidebar: sidebar,
      tabs: tabs,
      status: %{x: 0, y: main_h, w: cols, h: min(rows, 1)},
      panes: %{x: sw, y: top, w: main_w, h: max(main_h - top, 0)}
    }
  end

  defp sidebar(%{visible: true} = s, cols, main_h) when main_h > 0 do
    w = if s.collapsed, do: @collapsed, else: s.width |> max(s.min) |> min(s.max)
    if cols >= w + @min_main, do: %{x: 0, y: 0, w: min(w, cols - 1), h: main_h}
  end

  defp sidebar(_hidden, _cols, _main_h), do: nil
end
