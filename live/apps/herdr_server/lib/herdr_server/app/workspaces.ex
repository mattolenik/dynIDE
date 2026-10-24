defmodule HerdrServer.App.Workspaces do
  @moduledoc """
  Pure workspace and focus actions, delegated from `HerdrServer.App.Actions`: create,
  switch, close, step, rename, and `focus_pane/2` (jump to a pane in any workspace or tab).
  Returns `{app, effects}` like the other actions.

  Panes of inactive workspaces stay alive; the Store's `settle/1` hides every pane that is
  not in the active tab, so switching needs no effect here.

  Gap vs herdr: a new workspace is named `"workspace"`, `"workspace 2"`, ... instead of
  from the cwd.
  """

  alias HerdrServer.App.Actions
  alias HerdrServer.Layout

  @type app :: Actions.app()
  @type effect :: Actions.effect()

  @spec new_workspace(app()) :: {app(), [effect()]}
  def new_workspace(app) do
    s = app.session
    {id, layout} = {s.next_id, Layout.new(s.next_id)}
    ws_id = Enum.max([0 | Enum.map(s.workspaces, & &1.id)]) + 1
    ws = %{id: ws_id, name: free_name(s.workspaces), tabs: [tab(layout)], active_tab: 1}

    app = %{app | session: %{s | workspaces: s.workspaces ++ [ws], next_id: id + 1}}
    app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
    {activate(app, ws_id), [{:spawn, id, spawn_size(layout, s.area, id)}]}
  end

  @doc "Switch to the `n`th workspace (1-based); out of range is a no-op."
  @spec switch_workspace(app(), integer()) :: {app(), [effect()]}
  def switch_workspace(app, n) when n >= 1 do
    case Enum.at(app.session.workspaces, n - 1) do
      nil -> {app, []}
      ws -> {activate(app, ws.id), []}
    end
  end

  def switch_workspace(app, _n), do: {app, []}

  @spec switch_workspace_id(app(), term()) :: {app(), [effect()]}
  def switch_workspace_id(app, id) do
    if Enum.any?(app.session.workspaces, &(&1.id == id)),
      do: {activate(app, id), []},
      else: {app, []}
  end

  @spec next_workspace(app()) :: {app(), [effect()]}
  def next_workspace(app), do: step(app, 1)

  @spec previous_workspace(app()) :: {app(), [effect()]}
  def previous_workspace(app), do: step(app, -1)

  @doc "Closes the active workspace; the last one is replaced by a fresh one."
  @spec close_workspace(app()) :: {app(), [effect()]}
  def close_workspace(app) do
    s = app.session
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    ids = Enum.flat_map(ws.tabs, &Layout.pane_ids(&1.layout))
    closes = Enum.map(ids, &{:close, &1})
    i = Enum.find_index(s.workspaces, &(&1.id == ws.id))
    app = update_in(app.session.panes, &Map.drop(&1, ids))
    app = update_in(app.session.workspaces, &List.delete_at(&1, i))

    case app.session.workspaces do
      [] ->
        {app, spawn} = new_workspace(app)
        {app, closes ++ spawn}

      rest ->
        {activate(app, Enum.at(rest, max(i - 1, 0)).id), closes}
    end
  end

  @doc "Focuses pane `id`, switching to its workspace and tab; unknown ids are a no-op."
  @spec focus_pane(app(), term()) :: {app(), [effect()]}
  def focus_pane(app, id) do
    found =
      for ws <- app.session.workspaces, t <- ws.tabs, id in Layout.pane_ids(t.layout), do: {ws, t}

    case found do
      [{ws, t} | _] ->
        app = put_ws(app, %{ws | active_tab: t.id, tabs: put_layout(ws.tabs, t, id)})
        {activate(app, ws.id), []}

      [] ->
        {app, []}
    end
  end

  @doc "Renames tab `tab_id` of workspace `ws_id` (tab ids are per workspace)."
  @spec rename_tab(app(), term(), term(), binary()) :: {app(), [effect()]}
  def rename_tab(app, ws_id, tab_id, name) do
    {update_in(app.session.workspaces, fn l ->
       Enum.map(l, fn
         %{id: ^ws_id} = ws ->
           %{ws | tabs: Enum.map(ws.tabs, &if(&1.id == tab_id, do: %{&1 | name: name}, else: &1))}

         ws ->
           ws
       end)
     end), []}
  end

  @spec rename_workspace(app(), term(), binary()) :: {app(), [effect()]}
  def rename_workspace(app, ws_id, name) do
    {update_in(app.session.workspaces, fn l ->
       Enum.map(l, &if(&1.id == ws_id, do: %{&1 | name: name}, else: &1))
     end), []}
  end

  @doc "Stores `name` in the pane's meta; the border shows it when the program set no title."
  @spec rename_pane(app(), term(), binary()) :: {app(), [effect()]}
  def rename_pane(app, id, name) do
    case app.session.panes do
      %{^id => meta} -> {put_in(app.session.panes[id], Map.put(meta, :name, name)), []}
      _ -> {app, []}
    end
  end

  # --- helpers ---

  defp tab(layout), do: %{id: 1, name: "1", layout: layout}

  defp free_name(workspaces) do
    names = MapSet.new(workspaces, & &1.name)

    Enum.find_value(1..(length(workspaces) + 1), fn
      1 -> if "workspace" not in names, do: "workspace"
      n -> if "workspace #{n}" not in names, do: "workspace #{n}"
    end)
  end

  defp step(app, d) do
    ws = app.session.workspaces
    i = Enum.find_index(ws, &(&1.id == app.session.active_workspace))
    switch_workspace(app, rem(i + d + length(ws), length(ws)) + 1)
  end

  defp activate(app, ws_id) do
    app = put_in(app.session.active_workspace, ws_id)
    ws = Enum.find(app.session.workspaces, &(&1.id == ws_id))
    t = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    put_in(app.focus.pane, t.layout.focus)
  end

  defp put_ws(app, ws) do
    update_in(app.session.workspaces, fn l ->
      Enum.map(l, &if(&1.id == ws.id, do: ws, else: &1))
    end)
  end

  defp put_layout(tabs, t, id),
    do:
      Enum.map(
        tabs,
        &if(&1.id == t.id, do: %{&1 | layout: Layout.focus(&1.layout, id)}, else: &1)
      )

  defp spawn_size(l, area, id) do
    %{rect: r} = Enum.find(Layout.borders(Layout.panes(l, area), area), &(&1.id == id))
    %{cols: r.w, rows: r.h}
  end
end
