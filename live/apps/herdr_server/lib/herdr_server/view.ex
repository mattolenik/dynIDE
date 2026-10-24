defmodule HerdrServer.View do
  @moduledoc """
  Pure per-client scene computation: `compute(app, client)` turns app state into a
  frontend-neutral `HerdrScene.Scene`.

    * Regions come from `View.Frame.regions/2` at the client's own size (sidebar, top tab
      bar, full-width status row, pane area), so every client gets its own rects; pane ids
      are shared.
    * Panes follow `Layout.panes` preorder inside the pane area. `Pane.rect` is the content
      rect, the border carries the outer rect (see `Layout.borders/2`). Rows are
      `{:ref, id, layout_gen}` (or `{:inline, []}` for inline clients; the caller fills
      rows). Cursors are nil here.
    * Chrome: `:root` (props `theme`, `indicators` and `mouse: true`) holding the
      `:sidebar` region (`View.Sidebar`, omitted when the frame has none), the `:tabs`
      region (`View.Tabs`, omitted when the frame has no tab bar), one `:divider` node per
      split in `Layout.splits` preorder, then the `:status` region (`View.Status`).
    * Divider rect choice: with borders on, a split's boundary is `pos`, the first cell of
      the second child. The divider is the 1-cell line at `pos` (second child's leading
      border column or row), spanning the split's area. A client resolves
      `{:chrome, [{:divider, path}], :drag}` against it.
    * A divider's `direction` names the split: `:horizontal` means panes side by side, so
      the divider line itself is vertical (and `:vertical` gives a horizontal line).
    * Divider rects are clamped into the pane area; pane rects are inside it by
      `Layout.borders/2`, so tiny clients never produce invalid scenes.
  """

  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Pane}
  alias HerdrServer.Client.State
  alias HerdrServer.Layout
  alias HerdrServer.View.{Frame, Sidebar, Status, Tabs}

  @spec compute(map, State.t()) :: Scene.t()
  def compute(app, %State{size: %{cols: cols, rows: rows} = size, transport: transport} = client) do
    regions = Frame.regions(size, app.ui)
    area = regions.panes
    ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    layout = tab.layout

    panes =
      layout
      |> Layout.panes(area)
      |> Layout.borders(area)
      |> Enum.map(&pane(&1, app, transport))

    %Scene{
      size: %{cols: cols, rows: rows},
      panes: panes,
      chrome: chrome(app, client, ws, layout, regions),
      focus: %{pane: app.focus.pane, chrome: nil}
    }
  end

  defp pane(%{id: id, rect: rect, border: border}, app, transport) do
    meta = Map.get(app.session.panes, id, %{title: nil, layout_gen: 0})

    %Pane{
      id: id,
      rect: rect,
      border: border && %{border | title: meta.title || Map.get(meta, :name)},
      rows: if(transport == :inline, do: {:inline, []}, else: {:ref, id, meta.layout_gen})
    }
  end

  defp chrome(app, client, ws, layout, %{panes: area} = regions) do
    sidebar = if regions.sidebar, do: [Sidebar.node(app, regions.sidebar)], else: []
    tabs = if regions.tabs, do: [Tabs.node(ws, regions.tabs)], else: []

    dividers =
      for s <- Layout.splits(layout, area) do
        %Node{
          role: :divider,
          id: {:divider, s.path},
          rect: divider_rect(s, area),
          props: %{direction: s.direction, path: s.path}
        }
      end

    status = Status.node(app, client, regions.status)
    props = %{theme: app.ui.theme, indicators: app.ui.indicators, mouse: true}
    %Node{role: :root, id: :root, props: props, children: sidebar ++ tabs ++ dividers ++ [status]}
  end

  defp divider_rect(%{direction: :horizontal, pos: pos, area: a}, area),
    do: clamp(%{x: pos, y: a.y, w: 1, h: a.h}, area)

  defp divider_rect(%{direction: :vertical, pos: pos, area: a}, area),
    do: clamp(%{x: a.x, y: pos, w: a.w, h: 1}, area)

  defp clamp(r, a) do
    x = r.x |> max(a.x) |> min(a.x + a.w)
    y = r.y |> max(a.y) |> min(a.y + a.h)
    %{x: x, y: y, w: max(min(r.w, a.x + a.w - x), 0), h: max(min(r.h, a.y + a.h - y), 0)}
  end
end
