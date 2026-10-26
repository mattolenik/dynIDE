defmodule DynideServer.App.Workspaces do
  @moduledoc """
  Pure workspace and focus actions, delegated from `DynideServer.App.Actions`: create,
  switch, close, step, rename, move, and `focus_pane/2` (jump to a pane in any workspace or tab).
  Returns `{app, effects}` like the other actions.

  Panes of inactive workspaces stay alive; the Store's `settle/1` hides every pane that is
  not in the active tab, so switching needs no effect here.

  A workspace created without a name is `auto_name: true`: it starts as `"workspace"`,
  `"workspace 2"`, ... and the server-internal `workspace_cwd/4` (from `WorkspaceFacts`,
  which computes the label with `Workspaces.Label.auto/1`) renames it after its root
  pane's repo or cwd until a user renames it.
  """

  alias DynideServer.App.Actions
  alias DynideServer.Layout

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
    {app, [{:spawn, id, Layout.size(layout, app.session.area, Layout.opts(nil, app.ui), id)}]}
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

  @doc """
  Moves tab `tab_id` of workspace `ws_id` to position `index` (0-based, clamped to
  `0..len-1`); ids and the active tab are kept. Unknown ids or no change are a no-op.
  A move gives the effect `{:api_event, {:tab_moved, ws_id, tab_id, insert_index}}`
  (`Api.Events` publishes `tab.moved`), `insert_index` the equivalent herdr gap
  (`index + 1` when moving right, else `index`). Both the API (`Commands`) and a chrome
  drop move through here.
  """
  @spec move_tab(app(), term(), term(), integer()) :: {app(), [effect()]}
  def move_tab(app, ws_id, tab_id, index) do
    with %{} = ws <- Enum.find(app.session.workspaces, &(&1.id == ws_id)),
         {:ok, tabs, insert} <- move(ws.tabs, tab_id, index) do
      {update_ws(app, ws_id, &%{&1 | tabs: tabs}),
       [{:api_event, {:tab_moved, ws_id, tab_id, insert}}]}
    else
      _ -> {app, []}
    end
  end

  @doc """
  Moves workspace `ws_id` to position `index`, as `move_tab/4`; the effect is
  `{:api_event, {:workspace_moved, ws_id, insert_index}}`.
  """
  @spec move_workspace(app(), term(), integer()) :: {app(), [effect()]}
  def move_workspace(app, ws_id, index) do
    case move(app.session.workspaces, ws_id, index) do
      {:ok, wss, insert} ->
        {put_in(app.session.workspaces, wss), [{:api_event, {:workspace_moved, ws_id, insert}}]}

      :error ->
        {app, []}
    end
  end

  # the moved list and the herdr gap index of the move; :error for no id or no change
  defp move(list, id, index) do
    with i when is_integer(i) <- Enum.find_index(list, &(&1.id == id)),
         {x, rest} = List.pop_at(list, i),
         j = index |> max(0) |> min(length(rest)),
         true <- j != i do
      {:ok, List.insert_at(rest, j, x), if(j > i, do: j + 1, else: j)}
    else
      _ -> :error
    end
  end

  @doc "A user rename: the workspace keeps `name` (`auto_name: false`)."
  @spec rename_workspace(app(), term(), binary()) :: {app(), [effect()]}
  def rename_workspace(app, ws_id, name),
    do: {update_ws(app, ws_id, &Map.merge(&1, %{name: name, auto_name: false})), []}

  @doc """
  Server-internal: stores workspace `ws_id`'s root-pane `cwd` (not persisted) and, while
  it is `auto_name`, renames it to `label` when that is non-nil. Pure: the label is
  computed by the sender (`WorkspaceFacts`).
  """
  @spec workspace_cwd(app(), term(), binary() | nil, binary() | nil) :: {app(), [effect()]}
  def workspace_cwd(app, ws_id, cwd, label),
    do: {update_ws(app, ws_id, &auto_name(Map.put(&1, :cwd, cwd), label)), []}

  @doc """
  Server-internal: stores workspace `ws_id`'s git facts (`GitStatus.info` or nil; not
  persisted) from `WorkspaceFacts`.
  """
  @spec workspace_git(app(), term(), map() | nil) :: {app(), [effect()]}
  def workspace_git(app, ws_id, info),
    do: {update_ws(app, ws_id, &Map.put(&1, :git, info)), []}

  defp auto_name(%{auto_name: true} = ws, label) when is_binary(label), do: %{ws | name: label}
  defp auto_name(ws, _label), do: ws

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
    # the new workspace's tab count may show or hide the tab bar
    Actions.reframe(put_in(app.focus.pane, t.layout.focus))
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
