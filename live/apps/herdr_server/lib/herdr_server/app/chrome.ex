defmodule HerdrServer.App.Chrome do
  @moduledoc """
  Pure chrome actions: `apply/3` resolves a client's `{:chrome, path, {kind, %{x, y}}}`
  (delegated from `App.Actions.apply/2`) to an action, returning `{app, effects}`.

    * `[:tabs, {:tab, id}]` click switches to the tab; wheel anywhere on `[:tabs | _]`
      steps tabs; `[:tabs, :new_tab]` click opens a tab (`Modal.Prompt.new_tab/1`: asks
      for its name when `ui.prompt_new_tab_name`).
    * `[{:divider, split_path}]` drag / drop sets the split's ratio from the pointer's
      position in the split's area along its direction (clamped 0.1-0.9 by `Layout`); a
      pointer on the divider's current line changes nothing (no rounding drift on a
      plain press and release).
    * `[:sidebar, :edge]` drag / drop sets `ui.sidebar.width` to `x + 1` clamped to
      `min..max`, double click resets it to 26; `[:sidebar, :split]` drag / drop sets
      `ui.sidebar.split` to the pointer row's share of the sidebar height (0.1-0.9);
      `[:sidebar, :toggle]` click collapses / expands. Each recomputes `session.area`.
    * `[:sidebar, :spaces, :list, {:workspace, id}]` click switches workspace,
      `[:sidebar, :spaces, :new]` click creates one, `[:sidebar, :agents, :list, {:pane,
      id}]` click focuses the pane.
    * Wheel over `[:sidebar, :spaces | _]` / `[:sidebar, :agents | _]` moves
      `ui.sidebar.spaces_offset` / `agents_offset` by one, clamped to `0..items - 1`
      (the server does not know the client's row heights). `View.Sidebar` puts it in the
      list's `offset` prop; the client rasterizer is the one owner of skipping items.
    * `[{:modal, _} | _]`, `[{:menu, _} | _]` go to the top modal (`App.Modal.chrome/3`).
    * Right clicks on a tab, a workspace or an agents item open its context menu at the
      click; the sidebar's `menu` button opens the global menu (`App.Modal.Menu`).
    * Unknown paths: no-op.
  """

  alias HerdrServer.App.{Actions, Modal}
  alias HerdrServer.App.Modal.{Menu, Prompt}
  alias HerdrServer.Layout
  alias HerdrServer.View.Frame

  @width_default 26

  @spec apply(Actions.app(), [term], {atom, %{x: integer, y: integer}}) ::
          {Actions.app(), [Actions.effect()]}
  def apply(app, [:tabs, {:tab, id}], {:click, _}) do
    case Enum.find_index(ws(app).tabs, &(&1.id == id)) do
      nil -> {app, []}
      i -> Actions.switch_tab(app, i + 1)
    end
  end

  def apply(app, [{tag, _} | _] = path, action) when tag in [:modal, :menu],
    do: Modal.chrome(app, path, action)

  def apply(app, [:tabs, {:tab, id}], {:right_click, at}), do: Menu.open(app, :tab, id, at)

  def apply(app, [:sidebar, :spaces, :list, {:workspace, id}], {:right_click, at}),
    do: Menu.open(app, :workspace, id, at)

  def apply(app, [:sidebar, :agents, :list, {:pane, id}], {:right_click, at}),
    do: Menu.open(app, :pane, id, at)

  def apply(app, [:sidebar, :spaces, :menu], {:click, at}), do: Menu.open(app, :global, nil, at)

  def apply(app, [:tabs, :new_tab], {:click, _}), do: Prompt.new_tab(app)
  def apply(app, [:tabs | _], {:scroll_up, _}), do: Actions.previous_tab(app)
  def apply(app, [:tabs | _], {:scroll_down, _}), do: Actions.next_tab(app)

  def apply(app, [{:divider, path}], {kind, at}) when kind in [:drag, :drop],
    do: {divider(app, path, at), []}

  def apply(app, [:sidebar, :edge], {kind, %{x: x}}) when kind in [:drag, :drop],
    do: {width(app, x + 1), []}

  def apply(app, [:sidebar, :edge], {:double_click, _}), do: {width(app, @width_default), []}

  def apply(app, [:sidebar, :split], {kind, %{y: y}}) when kind in [:drag, :drop] do
    case Frame.regions(app.session.size, app.ui).sidebar do
      nil ->
        {app, []}

      r ->
        split = ((y - r.y) / max(r.h, 1)) |> max(0.1) |> min(0.9)
        {put_in(app.ui.sidebar[:split], split), []}
    end
  end

  def apply(app, [:sidebar, :toggle], {:click, _}), do: Actions.toggle_sidebar(app)

  def apply(app, [:sidebar, :spaces, :list, {:workspace, id}], {:click, _}),
    do: Actions.switch_workspace_id(app, id)

  def apply(app, [:sidebar, :spaces, :new], {:click, _}), do: Actions.new_workspace(app)

  def apply(app, [:sidebar, :agents, :list, {:pane, id}], {:click, _}),
    do: Actions.focus_pane(app, id)

  def apply(app, [:sidebar, section | _], {kind, _})
      when section in [:spaces, :agents] and kind in [:scroll_up, :scroll_down],
      do: {scroll(app, section, if(kind == :scroll_up, do: -1, else: 1)), []}

  def apply(app, _path, _action), do: {app, []}

  defp divider(app, path, %{x: x, y: y}) do
    w = ws(app)
    tab = Enum.find(w.tabs, &(&1.id == w.active_tab))

    case Enum.find(Layout.splits(tab.layout, app.session.area), &(&1.path == path)) do
      nil ->
        app

      %{direction: :horizontal, pos: pos} when x == pos ->
        app

      %{direction: :vertical, pos: pos} when y == pos ->
        app

      %{direction: dir, area: a} ->
        ratio = if dir == :horizontal, do: (x - a.x) / max(a.w, 1), else: (y - a.y) / max(a.h, 1)
        l = Layout.set_ratio(tab.layout, path, ratio)
        tabs = Enum.map(w.tabs, &if(&1.id == tab.id, do: %{&1 | layout: l}, else: &1))
        put_ws(app, %{w | tabs: tabs})
    end
  end

  defp width(app, w) do
    s = app.ui.sidebar
    Actions.reframe(put_in(app.ui.sidebar[:width], w |> max(s.min) |> min(s.max)))
  end

  defp scroll(app, section, d) do
    key = if section == :spaces, do: :spaces_offset, else: :agents_offset
    n = if section == :spaces, do: length(app.session.workspaces), else: pane_count(app)

    update_in(
      app.ui.sidebar,
      &Map.put(&1, key, (Map.get(&1, key, 0) + d) |> min(n - 1) |> max(0))
    )
  end

  defp pane_count(app),
    do: Enum.sum(for w <- app.session.workspaces, t <- w.tabs, do: Layout.count(t.layout))

  defp ws(%{session: s}), do: Enum.find(s.workspaces, &(&1.id == s.active_workspace))

  defp put_ws(app, ws),
    do:
      update_in(
        app.session.workspaces,
        &Enum.map(&1, fn w -> if w.id == ws.id, do: ws, else: w end)
      )
end
