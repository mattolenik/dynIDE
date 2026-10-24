defmodule HerdrServer.View do
  @moduledoc """
  Pure per-client scene computation: `compute(app, client)` turns app state into a
  frontend-neutral `HerdrScene.Scene`.

    * The layout is computed at the client's own size (pane area = size minus the bottom
      status row), so every client gets its own rects; pane ids are shared.
    * Panes follow `Layout.panes` preorder. `Pane.rect` is the content rect, the border
      carries the outer rect (see `Layout.borders/2`). Rows are `{:ref, id, layout_gen}`
      (or `{:inline, []}` for inline clients; the caller fills rows). Cursors are nil here.
    * Chrome: `:root` holding a `:status` node (`:mode`, `:tabs`, `:notice` when the client
      has one, `:title`, `:hint`) and one
      `:divider` node per split, in `Layout.splits` preorder, after the status.
    * Divider rect choice: with borders on, a split's boundary is `pos`, the first cell of
      the second child. The divider is the 1-cell line at `pos` (second child's leading
      border column or row), spanning the split's area. A client resolves
      `{:chrome, [{:divider, path}], :drag}` against it.
    * A divider's `direction` names the split: `:horizontal` means panes side by side, so
      the divider line itself is vertical (and `:vertical` gives a horizontal line).
    * Divider rects are clamped into the pane area; pane rects are inside it by
      `Layout.borders/2`, so tiny clients never produce invalid scenes.
    * The `:mode` node shows the client's own input mode (`Client.State.mode`).
    * Self-describing chrome: the `:mode` node has `props: %{mode: mode}`, the `:hint` node
      `props: %{key: binary, mods: [atom]}` (the prefix key; empty props when hidden).
  """

  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Pane}
  alias HerdrServer.Client.State
  alias HerdrServer.Layout

  @spec compute(map, State.t()) :: Scene.t()
  def compute(app, %State{size: %{cols: cols, rows: rows} = size, transport: transport} = client) do
    area = %{x: 0, y: 0, w: cols, h: max(rows - 1, 0)}
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
      chrome: chrome(app, client.mode, ws, layout, size, area, client.notice),
      focus: %{pane: app.focus.pane, chrome: nil}
    }
  end

  defp pane(%{id: id, rect: rect, border: border}, app, transport) do
    meta = Map.get(app.session.panes, id, %{title: nil, layout_gen: 0})

    %Pane{
      id: id,
      rect: rect,
      border: border && %{border | title: meta.title},
      rows: if(transport == :inline, do: {:inline, []}, else: {:ref, id, meta.layout_gen})
    }
  end

  defp chrome(app, mode, ws, layout, %{cols: cols, rows: rows}, area, notice) do
    left = [mode(mode), tabs(ws)]
    hint = hint(mode, app.ui)

    status = %Node{
      role: :status,
      id: :status,
      rect: %{x: 0, y: rows - 1, w: cols, h: 1},
      children: left ++ notice(notice, cols - width(left) - width([hint])) ++ [title(app), hint]
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

  defp mode(m) do
    {label, token} =
      case m do
        :terminal -> {"TERMINAL", :default}
        :prefix -> {"PREFIX", :accent}
        :resize -> {"RESIZE", :warning}
      end

    %{text(:mode, label, token) | props: %{mode: m}}
  end

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

  defp hint(mode, ui) do
    case ui.keybinds.prefix do
      [{key, mods} | _] when mode in [:terminal, :prefix] and ui.status.show_hints ->
        label = Enum.map_join(mods ++ [key], "+", &to_string/1)
        %{text(:hint, label, :muted) | props: %{key: key, mods: mods}}

      _ ->
        text(:hint, "", :muted)
    end
  end

  # before the title so a long title cannot hide it; clipped to the cells left after the
  # mode, tabs and hint, dropped below 4 cells
  defp notice(nil, _free), do: []
  defp notice(_n, free) when free < 4, do: []

  defp notice(%{level: level, text: text}, free) do
    token = Map.get(%{error: :error, warning: :warning}, level, :muted)
    [text(:notice, String.slice(text, 0, free), token)]
  end

  # cells a status renderer gives these nodes: text, tabs as " i:name ", one gap after each
  defp width(nodes) do
    nodes
    |> Enum.map(fn
      %Node{role: :tabs, children: tabs} ->
        Enum.sum_by(tabs, &(String.length(" #{&1.props.index}:#{&1.text} ") + 1))

      %Node{text: t} when t in [nil, ""] ->
        0

      %Node{text: t} ->
        String.length(t) + 1
    end)
    |> Enum.sum()
  end

  defp text(id, text, token), do: %Node{role: :text, id: id, text: text, token: token}

  defp clamp(r, %{w: cw, h: ch}) do
    x = min(r.x, cw)
    y = min(r.y, ch)
    %{x: x, y: y, w: min(r.w, cw - x), h: min(r.h, ch - y)}
  end
end
