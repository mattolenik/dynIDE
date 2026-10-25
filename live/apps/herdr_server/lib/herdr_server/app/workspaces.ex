defmodule HerdrServer.App.Workspaces do
  @moduledoc """
  Pure workspace and focus actions, delegated from `HerdrServer.App.Actions`: create,
  switch, close, step, rename, and `focus_pane/2` (jump to a pane in any workspace or tab).
  Returns `{app, effects}` like the other actions.

  Panes of inactive workspaces stay alive; the Store's `settle/1` hides every pane that is
  not in the active tab, so switching needs no effect here.

  A workspace created without a name is `auto_name: true`: it starts as `"workspace"`,
  `"workspace 2"`, ... and the server-internal `workspace_cwd/3` (from `WorkspaceFacts`)
  renames it after its root pane's repo or cwd (`Workspaces.Label.auto/1`) until a user
  renames it.
  """

  alias HerdrServer.App.Actions
  alias HerdrServer.App.Workspaces.Label
  alias HerdrServer.Layout

  @type app :: Actions.app()
  @type effect :: Actions.effect()

  @spec new_workspace(app()) :: {app(), [effect()]}
  def new_workspace(app), do: new_workspace(app, nil, true)

  @doc "Adds a workspace named `name` (nil: the next free default name), focused when `focus?`."
  @spec new_workspace(app(), binary | nil, boolean) :: {app(), [effect()]}
  def new_workspace(app, name, focus?) do
    s = app.session
    {id, layout} = {s.next_id, Layout.new(s.next_id)}
    ws_id = s.next_workspace_id

    ws = %{
      id: ws_id,
      name: name || free_name(s.workspaces),
      auto_name: name == nil,
      tabs: [tab(layout)],
      active_tab: 1
    }

    s = %{s | workspaces: s.workspaces ++ [ws], next_id: id + 1, next_workspace_id: ws_id + 1}
    app = %{app | session: s}
    app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
    app = if focus?, do: activate(app, ws_id), else: app
    {app, [{:spawn, id, Layout.size(layout, s.area, Layout.opts(nil, app.ui), id)}]}
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
  def close_workspace(app), do: close_workspace(app, app.session.active_workspace)

  @doc """
  Closes workspace `ws_id`; the active workspace stays active unless it is the one closed
  (then the previous one is), and the last one is replaced by a fresh one. Unknown ids
  are a no-op.
  """
  @spec close_workspace(app(), term()) :: {app(), [effect()]}
  def close_workspace(app, ws_id) do
    case Enum.find_index(app.session.workspaces, &(&1.id == ws_id)) do
      nil -> {app, []}
      i -> drop_workspace(app, i)
    end
  end

  defp drop_workspace(app, i) do
    ws = Enum.at(app.session.workspaces, i)
    ids = Enum.flat_map(ws.tabs, &Layout.pane_ids(&1.layout))
    closes = Enum.map(ids, &{:close, &1})
    app = update_in(app.session.panes, &Map.drop(&1, ids))
    app = update_in(app.session.workspaces, &List.delete_at(&1, i))

    case app.session.workspaces do
      [] ->
        {app, spawn} = new_workspace(app)
        {app, closes ++ spawn}

      rest when app.session.active_workspace == ws.id ->
        {activate(app, Enum.at(rest, max(i - 1, 0)).id), closes}

      _ ->
        {app, closes}
    end
  end

  @doc """
  Runs `fun` (an active-workspace action) with workspace `ws_id` active, then re-activates
  the workspace that was active (when it still exists).
  """
  @spec within(app(), term(), (app() -> {app(), [effect()]})) :: {app(), [effect()]}
  def within(app, ws_id, fun) do
    back = app.session.active_workspace
    {app, []} = switch_workspace_id(app, ws_id)
    {app, effects} = fun.(app)

    case switch_workspace_id(app, back) do
      {app, []} -> {app, effects}
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

  @doc "A user rename: the workspace keeps `name` (`auto_name: false`)."
  @spec rename_workspace(app(), term(), binary()) :: {app(), [effect()]}
  def rename_workspace(app, ws_id, name),
    do: {update_ws(app, ws_id, &Map.merge(&1, %{name: name, auto_name: false})), []}

  @doc """
  Server-internal: stores workspace `ws_id`'s root-pane `cwd` (not persisted) and, while
  it is `auto_name`, renames it to `Label.auto(cwd)` when that is non-nil.
  """
  @spec workspace_cwd(app(), term(), binary() | nil) :: {app(), [effect()]}
  def workspace_cwd(app, ws_id, cwd),
    do: {update_ws(app, ws_id, &auto_name(Map.put(&1, :cwd, cwd))), []}

  defp auto_name(%{auto_name: true} = ws) do
    case Label.auto(ws.cwd) do
      nil -> ws
      name -> %{ws | name: name}
    end
  end

  defp auto_name(ws), do: ws

  defp update_ws(app, ws_id, fun) do
    update_in(app.session.workspaces, fn l ->
      Enum.map(l, &if(&1.id == ws_id, do: fun.(&1), else: &1))
    end)
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
    do: Enum.map(tabs, &if(&1.id == t.id, do: refocus(&1, id), else: &1))

  # focusing a pane the tab's zoom hides clears the zoom
  defp refocus(t, id) do
    t = %{t | layout: Layout.focus(t.layout, id)}
    if Map.get(t, :zoom) in [nil, id], do: t, else: Map.delete(t, :zoom)
  end
end
