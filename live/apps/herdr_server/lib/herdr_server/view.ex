defmodule HerdrServer.View do
  @moduledoc """
  Pure per-client scene computation: `compute(app, client)` turns app state into a
  frontend-neutral `HerdrScene.Scene`.

    * The layout is computed at the client's own size (pane area = size minus the bottom
      status row), so every client gets its own rects; pane ids are shared.
    * Panes follow `Layout.panes` preorder. `Pane.rect` is the content rect, the border
      carries the outer rect (see `Layout.borders/2`). Rows are `{:ref, id, layout_gen}`
      (or `{:inline, []}` for inline clients; the caller fills rows). Cursors are nil here.
    * Chrome: `:root` holding a `:status` node (`:mode`, `:tabs`, `:title`, `:hint`) and one
      `:divider` node per split, in `Layout.splits` preorder, after the status.
    * Divider rect choice: with borders on, a split's boundary is `pos`, the first cell of
      the second child. The divider is the 1-cell line at `pos` (second child's leading
      border column or row), spanning the split's area. A client resolves
      `{:chrome, [{:divider, path}], :drag}` against it.
    * All rects are clamped into the pane area, so tiny clients never produce invalid scenes.
  """

  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Pane}
  alias HerdrServer.Client.State
  alias HerdrServer.Layout

  @spec compute(map, State.t()) :: Scene.t()
  def compute(app, %State{size: %{cols: cols, rows: rows} = size, transport: transport}) do
    area = %{x: 0, y: 0, w: cols, h: max(rows - 1, 0)}
    ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    layout = tab.layout

    panes =
      layout
      |> Layout.panes(area)
      |> Layout.borders(area)
      |> Enum.map(&pane(&1, app, transport, area))

    %Scene{
      size: %{cols: cols, rows: rows},
      panes: panes,
      chrome: chrome(app, ws, layout, size, area),
      focus: %{pane: app.focus.pane, chrome: nil}
    }
  end

  defp pane(%{id: id, rect: rect, border: border}, app, transport, area) do
    meta = Map.get(app.session.panes, id, %{title: nil, layout_gen: 0})

    %Pane{
      id: id,
      rect: clamp(rect, area),
      border: border && %{border | title: meta.title},
      rows: if(transport == :inline, do: {:inline, []}, else: {:ref, id, meta.layout_gen})
    }
  end

  defp chrome(app, ws, layout, %{cols: cols, rows: rows}, area) do
    status = %Node{
      role: :status,
      id: :status,
      rect: %{x: 0, y: rows - 1, w: cols, h: 1},
      children: [mode(app), tabs(ws), title(app), hint(app)]
    }

    dividers =
      for s <- Layout.splits(layout, area) do
        %Node{
          role: :divider,
          id: {:divider, s.path},
          rect: divider_rect(s, area),
          props: %{direction: s.direction, path: s.path}
        }
      end

    %Node{role: :root, id: :root, children: [status | dividers]}
  end

  defp divider_rect(%{direction: :horizontal, pos: pos, area: a}, area),
    do: clamp(%{x: pos, y: a.y, w: 1, h: a.h}, area)

  defp divider_rect(%{direction: :vertical, pos: pos, area: a}, area),
    do: clamp(%{x: a.x, y: pos, w: a.w, h: 1}, area)

  defp mode(%{focus: %{mode: :terminal}}), do: text(:mode, "TERMINAL", :default)
  defp mode(%{focus: %{mode: :prefix}}), do: text(:mode, "PREFIX", :accent)
  defp mode(%{focus: %{mode: :resize}}), do: text(:mode, "RESIZE", :warning)

  defp tabs(ws) do
    children =
      ws.tabs
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} ->
        %Node{
          role: :tab,
          id: {:tab, t.id},
          text: t.name,
          props: %{index: i, active: t.id == ws.active_tab}
        }
      end)

    %Node{role: :tabs, id: :tabs, children: children}
  end

  defp title(app) do
    meta = Map.get(app.session.panes, app.focus.pane)
    text(:title, (meta && meta.title) || "", :muted)
  end

  defp hint(%{focus: %{mode: mode}, ui: ui}) do
    label =
      case ui.keybinds.prefix do
        [key | _] when mode in [:terminal, :prefix] and ui.status.show_hints -> key_label(key)
        _ -> ""
      end

    text(:hint, label, :muted)
  end

  defp key_label({key, mods}), do: Enum.map_join(mods ++ [key], "+", &to_string/1)

  defp text(id, text, token), do: %Node{role: :text, id: id, text: text, token: token}

  defp clamp(r, %{w: cw, h: ch}) do
    x = min(r.x, cw)
    y = min(r.y, ch)
    %{x: x, y: y, w: min(r.w, cw - x), h: min(r.h, ch - y)}
  end
end
