defmodule HerdrServer.App.Commands do
  @moduledoc """
  Pure commands on explicit workspace, tab and pane ids, for the API (`App.Store.request/1`).
  Each is `(app, ...) -> {app, [effect]}` with the effects of `App.Actions`; an unknown id
  is a no-op returning the app unchanged and `[]`. Unlike `Actions`, nothing here depends
  on which workspace or tab is active; `app.focus.pane` is re-derived from the active
  tab's layout after every change. Workspace, close and rename commands delegate to
  `App.Workspaces` and the `App.Actions` close paths (run in the target workspace with
  `Workspaces.within/3`), so there is one implementation of each.
  """

  alias HerdrServer.App.{Actions, Session, Workspaces}
  alias HerdrServer.App.Modal.Menu
  alias HerdrServer.Layout

  @type app :: Actions.app()
  @type result :: {app(), [Actions.effect()]}

  @doc "Changes nothing; lets a read initialise the app through `Store.request/1`."
  @spec noop(app()) :: result()
  def noop(app), do: {app, []}

  @doc """
  An unlabelled workspace starts named after its id and stays `auto_name: true`, so
  `WorkspaceFacts` renames it from its root pane's repo or cwd (as herdr does); a label
  is kept.
  """
  @spec create_workspace(app(), String.t() | nil, boolean()) :: result()
  def create_workspace(app, label, focus?) do
    {app, fx} = Workspaces.new_workspace(app, label, focus?)
    ws = List.last(app.session.workspaces)
    if label, do: {app, fx}, else: {put_ws(app, %{ws | name: Integer.to_string(ws.id)}), fx}
  end

  @spec focus_workspace(app(), integer()) :: result()
  defdelegate focus_workspace(app, ws_id), to: Workspaces, as: :switch_workspace_id

  @spec rename_workspace(app(), integer(), String.t()) :: result()
  defdelegate rename_workspace(app, ws_id, label), to: Workspaces

  @doc """
  Moves a workspace to gap `insert` (herdr's `insert_index`: 0..len, len appends; the
  final position is `insert - 1` past its old one). Out of range warns.
  """
  @spec move_workspace(app(), integer(), integer()) :: result()
  def move_workspace(app, ws_id, insert) do
    with_ws(app, ws_id, fn _ ->
      gap(app, app.session.workspaces, ws_id, insert, &Workspaces.move_workspace(app, ws_id, &1))
    end)
  end

  @spec close_workspace(app(), integer()) :: result()
  def close_workspace(%{session: %{workspaces: [_only]}} = app, ws_id) do
    with_ws(app, ws_id, fn _ ->
      {app, [{:notice, %{level: :warning, text: "cannot close the last workspace"}}]}
    end)
  end

  def close_workspace(app, ws_id), do: Workspaces.close_workspace(app, ws_id)

  @spec create_tab(app(), integer(), String.t() | nil, boolean()) :: result()
  def create_tab(app, ws_id, label, focus?) do
    with_ws(app, ws_id, fn ws ->
      {app, fx} = Workspaces.within(app, ws_id, &Actions.new_tab/1)
      %{tabs: tabs} = new_ws = find_ws(app, ws_id)
      tab = List.last(tabs)
      # an unlabeled API tab is named after its id (API workspaces start so, then auto-name)
      tab = %{tab | name: label || Integer.to_string(tab.id)}
      active = if focus?, do: tab.id, else: ws.active_tab
      new_ws = %{new_ws | tabs: List.replace_at(tabs, -1, tab), active_tab: active}
      {sync(put_ws(app, new_ws)), fx}
    end)
  end

  @spec focus_tab(app(), integer(), integer()) :: result()
  def focus_tab(app, ws_id, tab_id) do
    with_tab(app, ws_id, tab_id, fn ws, _tab ->
      app = put_ws(app, %{ws | active_tab: tab_id})
      {sync(put_in(app.session.active_workspace, ws_id)), []}
    end)
  end

  @spec rename_tab(app(), integer(), integer(), String.t()) :: result()
  defdelegate rename_tab(app, ws_id, tab_id, label), to: Workspaces

  @doc "Moves a tab within its workspace to gap `insert`, as `move_workspace/3`."
  @spec move_tab(app(), integer(), integer(), integer()) :: result()
  def move_tab(app, ws_id, tab_id, insert) do
    with_tab(app, ws_id, tab_id, fn ws, _tab ->
      gap(app, ws.tabs, tab_id, insert, &Workspaces.move_tab(app, ws_id, tab_id, &1))
    end)
  end

  @spec close_tab(app(), integer(), integer()) :: result()
  def close_tab(app, ws_id, tab_id) do
    with_tab(app, ws_id, tab_id, fn _ws, _tab ->
      Workspaces.within(app, ws_id, &Actions.close_tab(&1, tab_id))
    end)
  end

  @doc """
  Splits `pane`. `spawn` is the new pane's `cwd` and `env` (a name => value map; the Store
  keeps herdr's own variables authoritative); both optional.
  """
  @spec split_pane(app(), integer(), :horizontal | :vertical, float(), boolean(), map()) ::
          result()
  def split_pane(app, pane, dir, ratio, focus?, spawn \\ %{}) do
    case locate(app, pane) do
      nil -> {app, []}
      {ws_id, tab_id} -> split_in(app, ws_id, tab_id, {pane, dir, ratio, focus?, spawn})
    end
  end

  defp split_in(app, ws_id, tab_id, {pane, dir, ratio, focus?, spawn}) do
    {id, app2} = take_id(app)
    tab = Enum.find(find_ws(app, ws_id).tabs, &(&1.id == tab_id))
    l = tab.layout
    l2 = Layout.split(l, pane, dir, id, ratio)
    # a split clears the tab's zoom, so the size check sees the pane's real tile
    opts = Layout.opts(Map.delete(tab, :zoom), app.ui)
    new = Layout.size(l2, app.session.area, opts, id)

    if big_enough?(new) and big_enough?(Layout.size(l2, app.session.area, opts, pane)) do
      l2 = if focus?, do: l2, else: restore_focus(l2, l)
      app2 = app2 |> put_tab_layout(ws_id, tab_id, l2) |> sync()
      {put_in(app2.session.panes[id], new_meta()), [spawn_effect(id, new, spawn)]}
    else
      {app, [{:notice, %{level: :warning, text: "pane too small to split"}}]}
    end
  end

  defp spawn_effect(id, size, spawn) when map_size(spawn) == 0, do: {:spawn, id, size}

  defp spawn_effect(id, size, spawn),
    do: {:spawn, id, size, %{cwd: spawn[:cwd], replay: nil, env: Map.to_list(spawn[:env] || %{})}}

  @doc "Focuses `pane`, then moves focus to its neighbour in `nav`."
  @spec focus_pane_dir(app(), integer(), Layout.nav()) :: result()
  def focus_pane_dir(app, pane, nav), do: on_focused(app, pane, &Actions.focus_dir(&1, nav))

  @doc "Focuses `pane`, then swaps it with its neighbour in `nav`."
  @spec swap_pane_dir(app(), integer(), Layout.nav()) :: result()
  def swap_pane_dir(app, pane, nav), do: on_focused(app, pane, &Actions.swap_dir(&1, nav))

  @doc "Focuses `pane`, then resizes its edge in `nav` by `delta` of the tab."
  @spec resize_pane_dir(app(), integer(), Layout.nav(), float()) :: result()
  def resize_pane_dir(app, pane, nav, delta),
    do: on_focused(app, pane, &Actions.resize_dir(&1, nav, delta))

  defp on_focused(app, pane, fun) do
    case locate(app, pane) do
      nil ->
        {app, []}

      _ ->
        {app, fx} = Workspaces.focus_pane(app, pane)
        {app, fx2} = fun.(app)
        {app, fx ++ fx2}
    end
  end

  @spec close_pane(app(), integer()) :: result()
  def close_pane(app, pane) do
    case locate(app, pane) do
      nil -> {app, []}
      {ws_id, _tab_id} -> Workspaces.within(app, ws_id, &Actions.close_pane(&1, pane))
    end
  end

  @doc "Names a pane (the border shows it when the program set no title); nil or \"\" clears it."
  @spec rename_pane(app(), integer(), String.t() | nil) :: result()
  def rename_pane(app, pane, label) when label in [nil, ""], do: Menu.clear_name(app, pane)
  def rename_pane(app, pane, label), do: Workspaces.rename_pane(app, pane, label)

  @spec focus_pane(app(), integer()) :: result()
  defdelegate focus_pane(app, pane), to: Workspaces

  @doc "Focuses `pane`, then zooms it (`true`), unzooms (`false`) or toggles (nil)."
  @spec zoom_pane(app(), integer(), boolean() | nil) :: result()
  def zoom_pane(app, pane, zoom) do
    case locate(app, pane) do
      nil ->
        {app, []}

      _ ->
        {app, []} = Workspaces.focus_pane(app, pane)
        if zoom == nil, do: Actions.toggle_zoom(app), else: Actions.set_zoom(app, zoom)
    end
  end

  @doc "The `{workspace_id, tab_id}` holding `pane`, or nil."
  @spec locate(app(), integer()) :: {integer(), integer()} | nil
  def locate(app, pane) do
    for ws <- app.session.workspaces, tab <- ws.tabs, pane in Layout.pane_ids(tab.layout) do
      {ws.id, tab.id}
    end
    |> List.first()
  end

  # --- helpers ---

  defp with_ws(app, ws_id, fun) do
    case find_ws(app, ws_id) do
      nil -> {app, []}
      ws -> fun.(ws)
    end
  end

  defp with_tab(app, ws_id, tab_id, fun) do
    with %{} = ws <- find_ws(app, ws_id),
         %{} = tab <- Enum.find(ws.tabs, &(&1.id == tab_id)) do
      fun.(ws, tab)
    else
      _ -> {app, []}
    end
  end

  defp gap(app, list, _id, insert, _move) when insert > length(list),
    do: {app, [{:notice, %{level: :warning, text: "insert_index #{insert} is out of bounds"}}]}

  defp gap(_app, list, id, insert, move) do
    i = Enum.find_index(list, &(&1.id == id))
    move.(if insert > i, do: insert - 1, else: insert)
  end

  defp find_ws(app, ws_id), do: Enum.find(app.session.workspaces, &(&1.id == ws_id))

  defp put_ws(app, ws) do
    update_in(app.session.workspaces, fn l ->
      Enum.map(l, &if(&1.id == ws.id, do: ws, else: &1))
    end)
  end

  defp put_tab_layout(app, ws_id, tab_id, l) do
    ws = find_ws(app, ws_id)
    tabs = Enum.map(ws.tabs, &if(&1.id == tab_id, do: unzoomed(&1, l), else: &1))
    put_ws(app, %{ws | tabs: tabs})
  end

  defp unzoomed(tab, l), do: Map.delete(%{tab | layout: l}, :zoom)

  # focus follows the active tab's layout; other tabs never touch app.focus
  defp sync(%{session: %Session{} = s} = app) do
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    tab = Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    put_in(app.focus.pane, tab.layout.focus)
  end

  # a background split leaves focus history alone: the new pane is not "previous"
  defp restore_focus(split_layout, old),
    do: %{split_layout | focus: old.focus, prev_focus: old.prev_focus}

  defp take_id(app), do: {app.session.next_id, update_in(app.session.next_id, &(&1 + 1))}

  defp new_meta, do: %{title: nil, layout_gen: 0}

  defp big_enough?(%{cols: c, rows: r}), do: c >= 2 and r >= 1
end
