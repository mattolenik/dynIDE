defmodule HerdrServer.Api.View do
  @moduledoc """
  Pure: the app's workspaces, tabs, panes and layouts as the JSON objects of
  `Api.Spec.objects/0` (atom-keyed maps, ids in public form).

  `focused` is the chain from the top: a workspace is focused when it is the active one,
  a tab when it is the active tab of the focused workspace, a pane when it is the focus of
  the layout of a focused tab. Pane cols and rows are the content size from the tab's
  layout over `session.area`, as the Store settles them.
  """

  alias HerdrServer.Api.Ids
  alias HerdrServer.App.Commands
  alias HerdrServer.Layout

  @type app :: HerdrServer.App.Actions.app()

  @spec workspace(app(), map()) :: map()
  def workspace(app, ws) do
    %{
      workspace_id: Ids.workspace(ws.id),
      label: ws.name,
      focused: ws_focused?(app, ws),
      tabs: length(ws.tabs),
      active_tab_id: Ids.tab(ws.id, ws.active_tab)
    }
  end

  @spec tab(app(), map(), map()) :: map()
  def tab(app, ws, tab) do
    %{
      tab_id: Ids.tab(ws.id, tab.id),
      workspace_id: Ids.workspace(ws.id),
      label: tab.name,
      focused: tab_focused?(app, ws, tab),
      panes: Layout.count(tab.layout),
      focused_pane_id: Ids.pane(tab.layout.focus)
    }
  end

  @doc "The pane object, or nil when no tab holds `id`."
  @spec pane(app(), pos_integer()) :: map() | nil
  def pane(app, id) do
    with {ws_id, tab_id} <- Commands.locate(app, id),
         {ws, tab} <- find_tab(app, ws_id, tab_id) do
      pane_in(app, ws, tab, id)
    else
      _ -> nil
    end
  end

  @spec panes(app(), map(), map()) :: [map()]
  def panes(app, ws, tab),
    do: Enum.map(Layout.pane_ids(tab.layout), &pane_in(app, ws, tab, &1))

  @spec layout(app(), map(), map()) :: map()
  def layout(_app, ws, tab) do
    %{
      tab_id: Ids.tab(ws.id, tab.id),
      workspace_id: Ids.workspace(ws.id),
      focused_pane_id: Ids.pane(tab.layout.focus),
      root: tree(tab.layout.root)
    }
  end

  @doc "`{workspace, tab}` structs for ids, or nil."
  @spec find_tab(app(), integer(), integer()) :: {map(), map()} | nil
  def find_tab(app, ws_id, tab_id) do
    with %{} = ws <- find_workspace(app, ws_id),
         %{} = tab <- Enum.find(ws.tabs, &(&1.id == tab_id)) do
      {ws, tab}
    else
      _ -> nil
    end
  end

  @spec find_workspace(app(), integer()) :: map() | nil
  def find_workspace(app, ws_id), do: Enum.find(app.session.workspaces, &(&1.id == ws_id))

  # --- internals ---

  defp pane_in(app, ws, tab, id) do
    size =
      Layout.size(tab.layout, app.session.area, Layout.opts(tab, app.ui), id) ||
        %{cols: 0, rows: 0}

    %{
      pane_id: Ids.pane(id),
      tab_id: Ids.tab(ws.id, tab.id),
      workspace_id: Ids.workspace(ws.id),
      title: facts(app, id).title,
      # herdr's `label`: the name `pane.rename` (or a plugin pane's entry title) set
      label: get_in(app.session.panes, [id, :name]),
      focused: tab_focused?(app, ws, tab) and tab.layout.focus == id,
      cols: size.cols,
      rows: size.rows
    }
  end

  # The one place a per-pane fact is read. `title` stays the session's: `Pane.Server`
  # puts the same sanitized title in `Pane.Facts` and sends it to the Store
  # (`:pane_title`), and reading the snapshot keeps this module pure, so `EventDiff`
  # still sees a title change between two snapshots. The pane object has no cwd or
  # scroll field; add them from `Pane.Facts.get/1` (read by the caller) if it gains them.
  defp facts(app, id), do: %{title: get_in(app.session.panes, [id, :title])}

  defp ws_focused?(app, ws), do: app.session.active_workspace == ws.id
  defp tab_focused?(app, ws, tab), do: ws_focused?(app, ws) and ws.active_tab == tab.id

  defp tree({:pane, id}), do: %{type: "pane", pane_id: Ids.pane(id)}

  defp tree({:split, dir, ratio, a, b}) do
    %{
      type: "split",
      direction: if(dir == :horizontal, do: "right", else: "down"),
      ratio: ratio,
      first: tree(a),
      second: tree(b)
    }
  end
end
