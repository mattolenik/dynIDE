defmodule HerdrServer.View.Sidebar do
  @moduledoc """
  The sidebar region (pure): a `:spaces` section (one `:item` per workspace, the `:new`
  and `:menu` buttons), the `:split` divider row (expanded only, and only when both
  sections get 3 rows), an `:agents` section (one `:item` per pane of every workspace in
  preorder, or with `ui.agent_panel_sort` `:priority` by state, stable within one; the
  `:sort` button names the order, `"grouped"` / `"priority"`), the `:toggle` button
  and the `:edge` divider on the right column.

  A workspace badge is the highest-priority `agent_state` of its panes (blocked > done >
  working > idle > unknown; panes without one are `:unknown`). An agent line names the
  pane's `agent`, else its title, else `"terminal"`; its `:tab` text shows only when the
  workspace has more than one tab. A workspace whose `git` fact (`WorkspaceFacts`) has a
  branch carries it as the item's `:detail`, `"main ↑1 ↓2"`, followed by the workspace's
  metadata token values (`App.Metadata.visible/1`, by key), all joined by `" · "`; a pane
  item's `:detail` is its pane's token values. Collapsed: sections and the `:sort` button
  carry no text. The workspace item under the client's workspace drag (`drag`,
  `View.DropMarker`) carries `drop_marker`. With the client's navigate preview
  (`navigate`, `%{ids, at}`, `Client.State`) every workspace item carries `selected`, true
  only on `ids[at]`.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Metadata
  alias HerdrServer.Layout
  alias HerdrServer.View.DropMarker

  @prio %{unknown: 0, idle: 1, working: 2, done: 3, blocked: 4}

  @doc "Attention priority of an `agent_state`: blocked > done > working > idle > other."
  @spec priority(term) :: 0..4
  def priority(state), do: Map.get(@prio, state, 0)

  @spec node(map, HerdrScene.Scene.rect(), map | nil, map | nil) :: Node.t()
  def node(app, rect, drag \\ nil, navigate \\ nil) do
    collapsed = app.ui.sidebar.collapsed
    label = &if(collapsed, do: nil, else: &1)
    w = rect.w - 1

    spaces = %Node{
      role: :section,
      id: :spaces,
      text: label.("spaces"),
      children: [
        %Node{
          role: :list,
          id: :list,
          props: %{offset: offset(app, :spaces_offset)},
          children: workspaces(app, drag, navigate)
        },
        %Node{role: :button, id: :new, text: "new", props: %{action: :new_workspace}},
        %Node{
          role: :button,
          id: :menu,
          text: "menu",
          props: %{action: :global_menu, attention: false}
        }
      ]
    }

    agents = %Node{
      role: :section,
      id: :agents,
      text: label.("agents"),
      children: [
        %Node{
          role: :list,
          id: :list,
          props: %{offset: offset(app, :agents_offset)},
          children: agents(app)
        },
        %Node{
          role: :button,
          id: :sort,
          text: label.(if app.ui.agent_panel_sort == :priority, do: "priority", else: "grouped"),
          props: %{action: :toggle_agent_sort}
        }
      ]
    }

    toggle = %Node{
      role: :button,
      id: :toggle,
      props: %{action: :toggle_sidebar, collapsed: collapsed}
    }

    edge = %Node{
      role: :divider,
      id: :edge,
      rect: %{x: rect.x + w, y: rect.y, w: 1, h: rect.h},
      props: %{direction: :horizontal, target: :sidebar_width}
    }

    %Node{
      role: :sidebar,
      id: :sidebar,
      rect: rect,
      props: %{collapsed: collapsed},
      children: [spaces] ++ split(collapsed, app.ui.sidebar.split, rect) ++ [agents, toggle, edge]
    }
  end

  # the agents section's first row; both sections at least 3 rows
  defp split(true, _ratio, _rect), do: []
  defp split(false, _ratio, %{h: h}) when h < 6, do: []

  defp split(false, ratio, rect) do
    y = (rect.h * ratio) |> round() |> max(3) |> min(rect.h - 3)

    [
      %Node{
        role: :divider,
        id: :split,
        rect: %{x: rect.x, y: rect.y + y, w: rect.w - 1, h: 1},
        props: %{direction: :vertical, target: :sidebar_split}
      }
    ]
  end

  defp workspaces(app, drag, navigate) do
    path = &[:sidebar, :spaces, :list, {:workspace, &1}]
    paths = Enum.map(app.session.workspaces, &path.(&1.id))
    preview = navigate && Enum.at(navigate.ids, navigate.at)

    app.session.workspaces
    |> Enum.with_index(1)
    |> Enum.map(fn {ws, i} ->
      state =
        ws
        |> pane_ids()
        |> Enum.map(&state(app, &1))
        |> Enum.max_by(&@prio[&1], fn -> :unknown end)

      %Node{
        role: :item,
        id: {:workspace, ws.id},
        props:
          %{active: ws.id == app.session.active_workspace, index: i}
          |> detail(branch(ws), Map.get(ws, :metadata))
          |> then(&if(navigate, do: Map.put(&1, :selected, ws.id == preview), else: &1))
          |> DropMarker.put(DropMarker.side(drag, path.(ws.id), paths)),
        children: [line(0, [badge(state), text(:workspace, ws.name)])]
      }
    end)
  end

  defp agents(%{ui: %{agent_panel_sort: :priority}} = app),
    do: app |> agent_items() |> Enum.sort_by(&(-@prio[&1.state])) |> Enum.map(& &1.node)

  defp agents(app), do: app |> agent_items() |> Enum.map(& &1.node)

  defp agent_items(app) do
    for ws <- app.session.workspaces, tab <- ws.tabs, id <- Layout.pane_ids(tab.layout) do
      meta = Map.get(app.session.panes, id) || %{}
      tab_text = if length(ws.tabs) > 1, do: [text(:tab, tab.name)], else: []
      name = Map.get(meta, :agent) || Map.get(meta, :title) || "terminal"

      state = state(app, id)

      node = %Node{
        role: :item,
        id: {:pane, id},
        props: detail(%{active: id == app.focus.pane}, [], Map.get(meta, :metadata)),
        children: [
          line(0, [badge(state), text(:workspace, ws.name)] ++ tab_text),
          line(1, [text(:agent, name)])
        ]
      }

      %{state: state, node: node}
    end
  end

  defp detail(props, lead, meta) do
    case lead ++ Enum.map(Metadata.visible(meta), &elem(&1, 1)) do
      [] -> props
      parts -> Map.put(props, :detail, Enum.join(parts, " · "))
    end
  end

  # `"main ↑1 ↓2"` from the workspace's git facts (arrows only when non-zero)
  defp branch(%{git: %{branch: b} = g}) when is_binary(b) do
    [
      [b, g.ahead > 0 && "↑#{g.ahead}", g.behind > 0 && "↓#{g.behind}"]
      |> Enum.filter(& &1)
      |> Enum.join(" ")
    ]
  end

  defp branch(_ws), do: []

  # the client skips `offset` items (one owner of the skip: the rasterizer)
  defp offset(app, key), do: Map.get(app.ui.sidebar, key, 0)

  defp pane_ids(ws), do: Enum.flat_map(ws.tabs, &Layout.pane_ids(&1.layout))

  defp state(app, id) do
    s = app.session.panes |> Map.get(id) |> Kernel.||(%{}) |> Map.get(:agent_state)
    if Map.has_key?(@prio, s), do: s, else: :unknown
  end

  defp line(n, children), do: %Node{role: :group, id: {:line, n}, children: children}

  defp badge(state),
    do: %Node{role: :badge, id: :state, props: %{kind: :agent_state, state: state}}

  defp text(id, t), do: %Node{role: :text, id: id, text: t}
end
