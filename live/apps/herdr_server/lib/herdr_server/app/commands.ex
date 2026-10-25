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
  alias HerdrServer.Layout

  @type app :: Actions.app()
  @type result :: {app(), [Actions.effect()]}

  @doc "Changes nothing; lets a read initialise the app through `Store.request/1`."
  @spec noop(app()) :: result()
  def noop(app), do: {app, []}

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
      # an unlabeled API tab is named after its id, as API workspaces are
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

  @spec close_tab(app(), integer(), integer()) :: result()
  def close_tab(app, ws_id, tab_id) do
    with_tab(app, ws_id, tab_id, fn _ws, _tab ->
      Workspaces.within(app, ws_id, &Actions.close_tab(&1, tab_id))
    end)
  end

  @spec split_pane(app(), integer(), :horizontal | :vertical, float(), boolean()) :: result()
  def split_pane(app, pane, dir, ratio, focus?) do
    case locate(app, pane) do
      nil -> {app, []}
      {ws_id, tab_id} -> split_in(app, ws_id, tab_id, {pane, dir, ratio, focus?})
    end
  end

  defp split_in(app, ws_id, tab_id, {pane, dir, ratio, focus?}) do
    {id, app2} = take_id(app)
    l = tab_layout(app, ws_id, tab_id)
    l2 = Layout.split(l, pane, dir, id, ratio)
    area = app.session.area
    new = size_of(l2, area, id)

    if big_enough?(new) and big_enough?(size_of(l2, area, pane)) do
      l2 = if focus?, do: l2, else: restore_focus(l2, l)
      app2 = app2 |> put_tab_layout(ws_id, tab_id, l2) |> sync()
      {put_in(app2.session.panes[id], new_meta()), [{:spawn, id, new}]}
    else
      {app, [{:notice, %{level: :warning, text: "pane too small to split"}}]}
    end
  end

  @spec close_pane(app(), integer()) :: result()
  def close_pane(app, pane) do
    case locate(app, pane) do
      nil -> {app, []}
      {ws_id, _tab_id} -> Workspaces.within(app, ws_id, &Actions.close_pane(&1, pane))
    end
  end

  @spec focus_pane(app(), integer()) :: result()
  defdelegate focus_pane(app, pane), to: Workspaces

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

  defp find_ws(app, ws_id), do: Enum.find(app.session.workspaces, &(&1.id == ws_id))

  defp put_ws(app, ws) do
    update_in(app.session.workspaces, fn l ->
      Enum.map(l, &if(&1.id == ws.id, do: ws, else: &1))
    end)
  end

  defp tab_layout(app, ws_id, tab_id),
    do: find_ws(app, ws_id).tabs |> Enum.find(&(&1.id == tab_id)) |> Map.fetch!(:layout)

  defp put_tab_layout(app, ws_id, tab_id, l) do
    ws = find_ws(app, ws_id)
    tabs = Enum.map(ws.tabs, &if(&1.id == tab_id, do: %{&1 | layout: l}, else: &1))
    put_ws(app, %{ws | tabs: tabs})
  end

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

  defp size_of(l, area, id) do
    %{rect: r} = Enum.find(Layout.borders(Layout.panes(l, area), area), &(&1.id == id))
    %{cols: r.w, rows: r.h}
  end

  defp big_enough?(%{cols: c, rows: r}), do: c >= 2 and r >= 1
end
