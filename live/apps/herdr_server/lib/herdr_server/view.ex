defmodule HerdrServer.View do
  @moduledoc """
  Pure per-client scene computation: `compute(app, client)` turns app state into a
  frontend-neutral `HerdrScene.Scene`.

    * Regions come from `View.Frame.regions/2` at the client's own size (sidebar, top tab
      bar, full-width status row, pane area), so every client gets its own rects; pane ids
      are shared.
    * Panes are `Layout.rects/3` (zoom, `ui.pane_borders`) in `Layout.panes` preorder inside
      the pane area. `Pane.rect` is the content rect, the border carries the outer rect. Rows are
      `{:ref, id, layout_gen}` (or `{:inline, []}` for inline clients; the caller fills
      rows). Pane cursors are nil here.
    * Chrome: `:root` (props `theme`, `indicators`, `mouse: true`, `window_title` (`View.WindowTitle`, omitted when nil), the `sound` prefs
      `%{enabled, command}` and `toast: %{delivery}`, plain data a client acts on) holding the
      `:sidebar` region (`View.Sidebar`, omitted when the frame has none), the `:tabs`
      region (`View.Tabs`, omitted when the frame has no tab bar), one `:divider` node per
      split in `Layout.splits` preorder (none while the tab is zoomed), then the `:status`
      region (`View.Status`), this client's `:toast` regions (`View.Toast`), then
      the top modal's `:modal` / `:menu` region (`App.Modal.view/2`) when the stack is
      non-empty. A prompt on top puts `focus.chrome` on its input and sets the scene
      `cursor` there (`View.Modal.cursor/1`); otherwise both are nil.
    * Divider rect choice: with borders on, a split's boundary is `pos`, the first cell of
      the second child. The divider is the 1-cell line at `pos` (second child's leading
      border column or row), spanning the split's area. A client resolves
      `{:chrome, [{:divider, path}], {:drag, %{x, y}}}` against it.
    * A divider's `direction` names the split: `:horizontal` means panes side by side, so
      the divider line itself is vertical (and `:vertical` gives a horizontal line).
    * Divider rects are clamped into the pane area; pane rects are inside it by
      `Layout.borders/3`, so tiny clients never produce invalid scenes.
  """

  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Pane}
  alias HerdrServer.App.Modal
  alias HerdrServer.Client.State
  alias HerdrServer.Layout
  alias HerdrServer.View.{Frame, Overlays, Sidebar, Status, Tabs, Toast, WindowTitle}
  alias HerdrServer.View.Modal, as: ModalView

  @spec compute(map, State.t()) :: Scene.t()
  def compute(app, %State{size: %{cols: cols, rows: rows} = size} = client) do
    regions = Frame.regions(size, app.ui)
    area = regions.panes
    ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    layout = tab.layout

    panes =
      layout
      |> Layout.rects(area, Layout.opts(tab, app.ui))
      |> Enum.map(&pane(&1, app, client))

    modal = Modal.view(app, size)
    {chrome_focus, cursor} = ModalView.cursor(modal) || {nil, nil}
    chrome = chrome(app, client, ws, tab, regions)

    %Scene{
      size: %{cols: cols, rows: rows},
      panes: panes,
      chrome: %{chrome | children: chrome.children ++ List.wrap(modal)},
      focus: %{pane: app.focus.pane, chrome: chrome_focus},
      cursor: cursor
    }
  end

  defp pane(%{id: id, rect: rect, border: border}, app, %State{transport: transport} = client) do
    meta = Map.get(app.session.panes, id, %{title: nil, layout_gen: 0})

    %Pane{
      id: id,
      rect: rect,
      border: border && %{border | title: meta.title || Map.get(meta, :name)},
      rows: if(transport == :inline, do: {:inline, []}, else: {:ref, id, meta.layout_gen}),
      overlays: Overlays.pane(id, rect, client),
      graphics: Map.get(client.graphics, id, [])
    }
  end

  defp chrome(app, client, ws, tab, %{panes: area} = regions) do
    sidebar = if regions.sidebar, do: [Sidebar.node(app, regions.sidebar)], else: []
    tabs = if regions.tabs, do: [Tabs.node(ws, regions.tabs)], else: []

    splits =
      if Layout.zoomed?(tab.layout, Map.get(tab, :zoom)),
        do: [],
        else: Layout.splits(tab.layout, area)

    dividers =
      for s <- splits do
        %Node{
          role: :divider,
          id: {:divider, s.path},
          rect: divider_rect(s, area),
          props: %{direction: s.direction, path: s.path}
        }
      end

    status = Status.node(app, client, regions.status)
    toasts = Toast.nodes(client.toasts, area)

    props = %{
      theme: app.ui.theme,
      indicators: app.ui.indicators,
      mouse: true,
      sound: app.ui.sound,
      toast: %{delivery: app.ui.toast.delivery}
    }

    props =
      case window_title(app, client) do
        nil -> props
        title -> Map.put(props, :window_title, title)
      end

    %Node{
      role: :root,
      id: :root,
      props: props,
      children: sidebar ++ tabs ++ dividers ++ [status | toasts]
    }
  end

  # a non-empty override wins over the template; no hostname: not a real session (pure
  # View callers), so no title; nil (prop omitted) while empty
  defp window_title(_app, %{hostname: nil}), do: nil

  defp window_title(app, client) do
    title = get_in(app.session.panes, [app.focus.pane, :title])

    with o when is_binary(o) <- client.window_title,
         t when is_binary(t) <- WindowTitle.clean(o) do
      t
    else
      _ -> WindowTitle.render(app.ui.window_title, app, title, client.hostname)
    end
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
