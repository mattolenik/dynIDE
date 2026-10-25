defmodule HerdrServer.Api.EventDiff do
  @moduledoc """
  Pure: the API events between two apps, as string-keyed maps
  `%{"event" => type, "workspace_id" => .., "tab_id" => .., "pane_id" => .., ...}`.

  Created, focused, updated and renamed events carry the `Api.View` object
  (`"workspace"`, `"tab"`, `"pane"`); closed events carry only ids (from the old app);
  `layout.updated` carries `"layout"` for each surviving tab whose split tree changed.
  Focus follows `Api.View`'s chain: an event fires when the focused workspace, tab or
  pane id changes. `pane.updated` fires when a surviving pane's object changes other than
  `focused` (title, size, tokens). Order: workspace, tab, pane, layout events; within each,
  closed, created, focused, then updated or renamed. `diff(nil, app)` is `[]`.
  `tab.moved` / `workspace.moved` are not diffs: the move reports them (`moved/2`).
  """

  alias HerdrServer.Api.{Ids, View}
  alias HerdrServer.Layout

  @type app :: HerdrServer.App.Actions.app()
  @type event :: %{required(String.t()) => term()}

  @spec diff(app() | nil, app() | nil) :: [event()]
  def diff(nil, _new), do: []
  def diff(_old, nil), do: []
  def diff(%{session: s}, %{session: s}), do: []

  def diff(old, new) do
    o = index(old)
    n = index(new)

    workspaces(old, new, o, n) ++
      tabs(old, new, o, n) ++ panes(old, new, o, n) ++ layouts(new, o, n)
  end

  # --- workspaces ---

  defp workspaces(old, new, o, n) do
    closed =
      for {id, _} <- o.ws_l,
          not Map.has_key?(n.ws, id),
          do: %{"event" => "workspace.closed", "workspace_id" => Ids.workspace(id)}

    created = for {id, ws} <- n.ws_l, not Map.has_key?(o.ws, id), do: ws_ev("created", new, ws)
    w = new.session.active_workspace

    focused =
      if w != old.session.active_workspace and Map.has_key?(n.ws, w),
        do: [ws_ev("focused", new, Map.fetch!(n.ws, w))],
        else: []

    renamed =
      for {id, ws} <- n.ws_l,
          (prev = o.ws[id]) && prev.name != ws.name,
          do: ws_ev("renamed", new, ws)

    closed ++ created ++ focused ++ renamed
  end

  defp ws_ev(kind, app, ws) do
    %{
      "event" => "workspace." <> kind,
      "workspace_id" => Ids.workspace(ws.id),
      "workspace" => View.workspace(app, ws)
    }
  end

  # --- tabs ---

  defp tabs(_old, new, o, n) do
    closed =
      for {{w, t}, _} <- o.tabs_l,
          not Map.has_key?(n.tabs, {w, t}),
          do: %{
            "event" => "tab.closed",
            "tab_id" => Ids.tab(w, t),
            "workspace_id" => Ids.workspace(w)
          }

    created =
      for {key, wt} <- n.tabs_l, not Map.has_key?(o.tabs, key), do: tab_ev("created", new, wt)

    focused =
      if n.tab != o.tab and n.tab != nil,
        do: [tab_ev("focused", new, Map.fetch!(n.tabs, n.tab))],
        else: []

    renamed =
      for {key, {_, tab} = wt} <- n.tabs_l,
          (prev = o.tabs[key]) && elem(prev, 1).name != tab.name,
          do: tab_ev("renamed", new, wt)

    closed ++ created ++ focused ++ renamed
  end

  defp tab_ev(kind, app, {ws, tab}) do
    %{
      "event" => "tab." <> kind,
      "tab_id" => Ids.tab(ws.id, tab.id),
      "workspace_id" => Ids.workspace(ws.id),
      "tab" => View.tab(app, ws, tab)
    }
  end

  @doc """
  The event of a move effect (`App.Workspaces.move_tab/4`, `move_workspace/3`) in `app`,
  the app after it: the moved id, the requested `insert_index` and the new order.
  Nil when the target is gone.
  """
  @spec moved(tuple(), app()) :: event() | nil
  def moved({:tab_moved, w, t, insert}, app) do
    with %{} = ws <- View.find_workspace(app, w) do
      %{
        "event" => "tab.moved",
        "tab_id" => Ids.tab(w, t),
        "workspace_id" => Ids.workspace(w),
        "insert_index" => insert,
        "tabs" => Enum.map(ws.tabs, &View.tab(app, ws, &1))
      }
    end
  end

  def moved({:workspace_moved, w, insert}, app) do
    %{
      "event" => "workspace.moved",
      "workspace_id" => Ids.workspace(w),
      "insert_index" => insert,
      "workspaces" => Enum.map(app.session.workspaces, &View.workspace(app, &1))
    }
  end

  # --- panes ---

  defp panes(old, new, o, n) do
    closed =
      for {id, {ws, tab}} <- o.panes_l,
          not Map.has_key?(n.panes, id),
          do: Map.put(ids(id, ws, tab), "event", "pane.closed")

    created =
      for {id, wt} <- n.panes_l,
          not Map.has_key?(o.panes, id),
          do: pane_ev("created", new, id, wt)

    focused =
      if n.pane != o.pane and n.pane != nil,
        do: [pane_ev("focused", new, n.pane, Map.fetch!(n.panes, n.pane))],
        else: []

    updated =
      for {id, wt} <- n.panes_l,
          Map.has_key?(o.panes, id),
          changed?(old, new, id, o, n),
          do: pane_ev("updated", new, id, wt)

    closed ++ created ++ focused ++ updated
  end

  # cheap check first: same place, title, tab layout and area means the same object
  defp changed?(old, new, id, o, n) do
    {ows, otab} = o.panes[id]
    {nws, ntab} = n.panes[id]

    same? =
      ows.id == nws.id and otab.layout == ntab.layout and old.session.area == new.session.area and
        title(old, id) == title(new, id) and metadata(old, id) == metadata(new, id)

    not same? and
      Map.delete(View.pane(old, id), :focused) != Map.delete(View.pane(new, id), :focused)
  end

  defp title(app, id), do: get_in(app.session.panes, [id, :title])
  defp metadata(app, id), do: get_in(app.session.panes, [id, :metadata])

  defp pane_ev(kind, app, id, {ws, tab}) do
    ids(id, ws, tab)
    |> Map.put("event", "pane." <> kind)
    |> Map.put("pane", View.pane(app, id))
  end

  defp ids(id, ws, tab) do
    %{
      "pane_id" => Ids.pane(id),
      "tab_id" => Ids.tab(ws.id, tab.id),
      "workspace_id" => Ids.workspace(ws.id)
    }
  end

  # --- layouts ---

  defp layouts(new, o, n) do
    for {key, {ws, tab}} <- n.tabs_l,
        (prev = o.tabs[key]) && elem(prev, 1).layout.root != tab.layout.root do
      %{
        "event" => "layout.updated",
        "tab_id" => Ids.tab(ws.id, tab.id),
        "workspace_id" => Ids.workspace(ws.id),
        "layout" => View.layout(new, ws, tab)
      }
    end
  end

  # --- index ---

  # lists keep the app's order for iteration, maps answer lookups
  defp index(app) do
    wss = app.session.workspaces
    tabs = for ws <- wss, tab <- ws.tabs, do: {{ws.id, tab.id}, {ws, tab}}

    panes =
      for {_, {_, tab} = wt} <- tabs, id <- Layout.pane_ids(tab.layout), do: {id, wt}

    w = app.session.active_workspace
    ws = Enum.find(wss, &(&1.id == w))
    tab = ws && Enum.find(ws.tabs, &(&1.id == ws.active_tab))

    ws_l = Enum.map(wss, &{&1.id, &1})

    %{
      ws_l: ws_l,
      ws: Map.new(ws_l),
      tabs_l: tabs,
      tabs: Map.new(tabs),
      panes_l: panes,
      panes: Map.new(panes),
      tab: tab && {ws.id, tab.id},
      pane: tab && tab.layout.focus
    }
  end
end
