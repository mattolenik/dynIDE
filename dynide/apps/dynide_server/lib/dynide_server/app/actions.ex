defmodule DynideServer.App.Actions do
  @moduledoc """
  Pure input handling: `apply/2` turns a neutral `DynideScene.Event` (plus the
  server-internal `{:pane_exited, id}`, `{:pane_title, id, title}`, `{:config_loaded, cfg}`,
  `{:pane_agent, id, label}`, `{:agent_state, id, state}`, `{:workspace_cwd, ws_id, cwd, label}`,
  `{:workspace_git, ws_id, info}`, `{:metadata_expire, now_ms}` (`App.Metadata.expire/2`) and `{:worktree_done, result}` (`App.Worktrees.done/2`), which are never accepted from clients) into new app
  state and a list of effects. Effects are the only side-effect channel; this module does no I/O and sends no messages.

  Effects: `{:spawn, id, %{cols, rows}}`, `{:close, id}`, `{:key, id, event}`,
  `{:mouse, id, event}` (coordinates pane-relative), `{:paste, id, binary}`,
  `{:focus_report, id, boolean}`, `{:notice, %{level, text}}`, `{:detach}`,
  `{:reload_config}`, `{:config_diagnostics, [binary]}`, `{:alert, alert}` (`App.Alerts`),
  `{:worktree, op, args}` (git off the Store, `App.Worktrees`), `{:custom_command, cmd, env,
  cwd}` (a shell command off the Store, `App.CustomCommands`).

  Config (`DynideServer.Config`): `init/2` and the server-internal `{:config_loaded, cfg}`,
  put the file over the ui (keybinds are always `Keybinds.default/0` plus the file); a
  loaded config with `onboarding` opens onboarding when no modal is open.

  `{:pane_exited, id}` emits `{:close, id}` (an open popup's pane also closes the popup); the Store must treat closing an already-gone
  pane as idempotent. Mouse `px` is passed through unchanged (not pane-relative) in M3.
  Keys arrive here already resolved by the client's `Client.Keys` and go to the focused
  pane; bindings are applied by the Store as `apply(m, f, [app | a])`. While the modal
  stack is non-empty, keys and pastes go to its top (`App.Modal`) and pane mouse events
  are dropped, except inside an open popup's pane (`App.Modal.Popup`).

  Ponytail: panes' `layout_gen` is not bumped here; the Store owns resize bookkeeping.
  """

  alias DynideServer.App.{
    Agents,
    Alerts,
    Chrome,
    Commands,
    Focus,
    Keybinds,
    Metadata,
    Modal,
    Session,
    Ui,
    Workspaces,
    Worktrees
  }

  alias DynideServer.App.Modal.{Onboarding, Popup}
  alias DynideServer.{Config, Layout}
  alias DynideServer.View.Frame

  @type app :: %{session: Session.t(), focus: Focus.t(), ui: Ui.t()}
  @type effect :: tuple()

  @spec init(%{cols: pos_integer(), rows: pos_integer()}, Config.t() | nil) ::
          {app(), [effect()]}
  def init(%{cols: c, rows: r}, cfg \\ nil) do
    size = %{cols: c, rows: r}
    {ui, fx} = configure(%Ui{keybinds: Keybinds.default()}, cfg, start: true)
    area = area(size, ui, 1)
    layout = Layout.new(1)

    session = %Session{
      workspaces: [
        %{
          id: 1,
          name: "1",
          auto_name: true,
          tabs: [%{id: 1, name: "1", layout: layout}],
          active_tab: 1
        }
      ],
      active_workspace: 1,
      panes: %{1 => %{title: nil, layout_gen: 0}},
      next_id: 2,
      next_workspace_id: 2,
      next_tab_id: 2,
      size: size,
      area: area
    }

    app = Onboarding.at_start(%{session: session, focus: %Focus{pane: 1}, ui: ui})

    {app, [{:spawn, 1, Layout.size(layout, area, Layout.opts(nil, ui), 1)} | fx]}
  end

  defp configure(ui, nil, _opts), do: {ui, []}

  defp configure(ui, cfg, opts) do
    {kb, ui, diags} = Config.apply(cfg, Keybinds.default(), ui, opts)
    {%{ui | keybinds: kb}, [{:config_diagnostics, diags}]}
  end

  # --- events ---

  @spec apply(app(), tuple()) :: {app(), [effect()]}
  # an open modal takes keys and pastes; pane mouse input waits until it closes, except
  # inside an open popup's pane
  def apply(%{focus: %{modal: [_ | _]}} = app, {:key, _} = event), do: Modal.key(app, event)
  def apply(%{focus: %{modal: [_ | _]}} = app, {:paste, bin}), do: Modal.paste(app, bin)
  def apply(%{focus: %{modal: [_ | _]}} = app, {:mouse, _} = ev), do: Popup.mouse(app, ev)

  # key resolution (prefix, modes, consumed releases) is per-client, in `Client.Keys`
  def apply(app, {:key, _} = event), do: to_focused(app, :key, event)

  def apply(app, {:paste, bin}), do: to_focused(app, :paste, bin)

  def apply(app, {:focus, b}) when is_boolean(b), do: to_focused(app, :focus_report, b)

  def apply(app, {:resize, %{cols: c, rows: r}}),
    do: {reframe(put_in(app.session.size, %{cols: c, rows: r})), []}

  def apply(app, {:mouse, m} = event) do
    hit = Enum.find(content_rects(app), &inside?(&1.rect, m.x, m.y))
    focused = app.focus.pane

    cond do
      hit && m.kind == :press && m.button == :left ->
        app = set_focus(app, hit.id)
        {app, [{:mouse, hit.id, rel(event, hit.rect)}]}

      hit && hit.id == focused ->
        {app, [{:mouse, hit.id, rel(event, hit.rect)}]}

      true ->
        {app, []}
    end
  end

  def apply(app, {:chrome, path, action}), do: Chrome.apply(app, path, action)

  def apply(app, {:pane_exited, id}), do: Popup.exited(app, id) || Commands.close_pane(app, id)

  def apply(app, {:pane_title, id, title}) do
    case app.session.panes do
      %{^id => meta} -> {put_in(app.session.panes[id], %{meta | title: clean_title(title)}), []}
      _ -> {app, []}
    end
  end

  # server-internal (`WorkspaceFacts`): the root pane's cwd, and an automatic name
  def apply(app, {:workspace_cwd, ws_id, cwd, label}),
    do: Workspaces.workspace_cwd(app, ws_id, cwd, label)

  def apply(app, {:workspace_git, ws_id, info}), do: Workspaces.workspace_git(app, ws_id, info)

  def apply(app, {:worktree_done, result}), do: Worktrees.done(app, result)

  # server-internal (the Store's metadata timer)
  def apply(app, {:metadata_expire, now}), do: Metadata.expire(app, now)

  # server-internal (M11 detection): the label; nil (no agent) also clears the state
  def apply(app, {:pane_agent, id, label}) do
    case app.session.panes do
      %{^id => meta} ->
        meta = Map.put(meta, :agent, label)
        meta = if label == nil, do: Map.put(meta, :agent_state, nil), else: meta
        {put_in(app.session.panes[id], meta), []}

      _ ->
        {app, []}
    end
  end

  # server-internal (M11 detection): stores the published status (`App.Agents`), alerts
  # on herdr's transitions
  def apply(app, {:agent_state, id, detected}) do
    case app.session.panes do
      %{^id => meta} ->
        old = Map.get(meta, :agent_state)
        state = Agents.status(app, id, old, detected)
        alerts = Alerts.from_agent(app, id, old, state)

        {put_in(app.session.panes[id], Map.put(meta, :agent_state, state)),
         Enum.map(alerts, &{:alert, &1})}

      _ ->
        {app, []}
    end
  end

  # a file that did not read or decode is not a config: only its diagnostics
  def apply(app, {:config_loaded, %{failed: true} = cfg}),
    do: {app, [{:config_diagnostics, cfg.diagnostics}]}

  def apply(app, {:config_loaded, cfg}) do
    {ui, fx} = configure(app.ui, cfg, [])
    app = reframe(%{app | ui: ui})
    {if(app.focus.modal == [], do: Onboarding.at_start(app), else: app), fx}
  end

  def apply(app, _other), do: {app, []}

  @doc """
  Runs a binding `{m, f, a}` as `apply(m, f, [app | a])` (the Store's `{:run, mfa}`).
  While a modal is open only `detach/1` runs: the modal takes every key, and its
  targets must not change beneath it.
  """
  @spec run(app(), Keybinds.mfa_t()) :: {app(), [effect()]}
  def run(%{focus: %{modal: [_ | _]}} = app, {m, f, a})
      when {m, f, a} != {__MODULE__, :detach, []},
      do: {app, []}

  def run(app, {m, f, a}), do: Kernel.apply(m, f, [app | a])

  @title_max 256

  # Titles come from programs: valid UTF-8, at most @title_max bytes, cut on a codepoint.
  defp clean_title(title) when is_binary(title) do
    t = String.replace_invalid(title)
    if byte_size(t) <= @title_max, do: t, else: whole_codepoints(binary_part(t, 0, @title_max))
  end

  defp clean_title(_other), do: nil

  # the generator stops at the cut codepoint's partial bytes
  defp whole_codepoints(bin), do: for(<<c::utf8 <- bin>>, into: "", do: <<c::utf8>>)

  defp to_focused(%{focus: %{pane: nil}} = app, _, _), do: {app, []}
  defp to_focused(app, tag, payload), do: {app, [{tag, app.focus.pane, payload}]}

  defp rel({:mouse, m}, r), do: {:mouse, %{m | x: m.x - r.x, y: m.y - r.y}}

  defp inside?(r, x, y), do: x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

  # --- actions ---

  @spec new_tab(app()) :: {app(), [effect()]}
  def new_tab(app) do
    {id, app} = take_id(app)
    {tab_id, app} = take_tab_id(app)
    ws = ws(app)
    layout = Layout.new(id)
    tab = %{id: tab_id, name: tab_name(ws.tabs), layout: layout}
    app = put_ws(app, %{ws | tabs: ws.tabs ++ [tab], active_tab: tab_id})
    app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
    app = reframe(app)
    {sync(app), [{:spawn, id, size_of(app, tab, layout, id)}]}
  end

  @spec close_tab(app()) :: {app(), [effect()]}
  def close_tab(app), do: drop_tab(app, ws(app).active_tab)

  @doc "Closes tab `tab_id` of the active workspace; unknown ids are a no-op."
  @spec close_tab(app(), term()) :: {app(), [effect()]}
  def close_tab(app, tab_id) do
    if Enum.any?(ws(app).tabs, &(&1.id == tab_id)), do: drop_tab(app, tab_id), else: {app, []}
  end

  @spec next_tab(app()) :: {app(), [effect()]}
  def next_tab(app), do: step_tab(app, 1)

  @spec previous_tab(app()) :: {app(), [effect()]}
  def previous_tab(app), do: step_tab(app, -1)

  @doc "Switch to the `n`th tab (1-based); out of range is a no-op."
  @spec switch_tab(app(), pos_integer()) :: {app(), [effect()]}
  def switch_tab(app, n) do
    ws = ws(app)

    case Enum.at(ws.tabs, n - 1) do
      nil -> {app, []}
      tab -> {sync(put_ws(app, %{ws | active_tab: tab.id})), []}
    end
  end

  @doc "Splits the focused pane; a zoom is cleared first, so the size check sees its tile."
  @spec split(app(), :horizontal | :vertical) :: {app(), [effect()]}
  def split(app0, dir) do
    app = unzoom(app0)

    with %{} = l <- layout(app), focus when not is_nil(focus) <- l.focus do
      {id, app2} = take_id(app)
      l2 = Layout.split(l, focus, dir, id)
      new = size_of(app, tab(app), l2, id)

      if big_enough?(new) and big_enough?(size_of(app, tab(app), l2, focus)) do
        app2 = app2 |> put_layout(l2) |> sync()
        app2 = put_in(app2.session.panes[id], %{title: nil, layout_gen: 0})
        {app2, [{:spawn, id, new}]}
      else
        {app0, [{:notice, %{level: :warning, text: "pane too small to split"}}]}
      end
    else
      _ -> {app0, []}
    end
  end

  defp big_enough?(%{cols: c, rows: r}), do: c >= 2 and r >= 1

  @spec close_pane(app()) :: {app(), [effect()]}
  def close_pane(app), do: close_pane_id(app, app.focus.pane)

  @spec close_pane(app(), term()) :: {app(), [effect()]}
  def close_pane(app, id), do: close_pane_id(app, id)

  @spec focus_dir(app(), Layout.nav()) :: {app(), [effect()]}
  def focus_dir(app, nav) do
    app = unzoom(app)
    l = layout(app)

    case Layout.find_in_direction(l, app.session.area, l.focus, nav) do
      nil -> {app, []}
      id -> {set_focus(app, id), []}
    end
  end

  @spec cycle(app(), :next | :previous) :: {app(), [effect()]}
  def cycle(app, which) do
    app = unzoom(app)
    l = layout(app)
    ids = Layout.pane_ids(l)
    i = Enum.find_index(ids, &(&1 == l.focus)) || 0

    {set_focus(
       app,
       Enum.at(ids, rem(i + if(which == :next, do: 1, else: -1) + length(ids), length(ids)))
     ), []}
  end

  @spec swap_dir(app(), Layout.nav()) :: {app(), [effect()]}
  def swap_dir(app, nav) do
    app = unzoom(app)
    l = layout(app)

    case Layout.find_in_direction(l, app.session.area, l.focus, nav) do
      nil -> {app, []}
      id -> {put_layout(app, Layout.swap(l, l.focus, id)), []}
    end
  end

  @spec resize_dir(app(), Layout.nav(), float()) :: {app(), [effect()]}
  def resize_dir(app, nav, delta) do
    app = unzoom(app)
    {put_layout(app, Layout.resize(layout(app), app.session.area, nav, delta)), []}
  end

  @doc """
  Zooms the focused pane to the whole pane area, or clears the active tab's zoom (herdr
  `zoom`). Emits nothing: the Store's settle resizes and hides panes. `tab.zoom` is never
  persisted; split, close, focus and swap moves, resizes and divider drags clear it.
  """
  @spec toggle_zoom(app()) :: {app(), [effect()]}
  def toggle_zoom(app), do: set_zoom(app, Map.get(tab(app), :zoom) == nil)

  @doc "Zooms the focused pane (`true`) or clears the active tab's zoom (`false`)."
  @spec set_zoom(app(), boolean()) :: {app(), [effect()]}
  def set_zoom(app, true), do: {put_zoom(app, app.focus.pane), []}
  def set_zoom(app, false), do: {unzoom(app), []}

  @spec detach(app()) :: {app(), [effect()]}
  def detach(app), do: {app, [{:detach}]}

  @doc "Reloads the config file (the Store loads it and applies `{:config_loaded, cfg}`)."
  @spec reload_config(app()) :: {app(), [effect()]}
  def reload_config(app), do: {app, [{:reload_config}]}

  @doc "Collapses or expands the sidebar (herdr `toggle_sidebar`); the pane area follows."
  @spec toggle_sidebar(app()) :: {app(), [effect()]}
  def toggle_sidebar(app),
    do: {reframe(update_in(app.ui.sidebar.collapsed, &(not &1))), []}

  defdelegate new_workspace(app), to: Workspaces
  defdelegate switch_workspace(app, n), to: Workspaces
  defdelegate switch_workspace_id(app, id), to: Workspaces
  defdelegate close_workspace(app), to: Workspaces
  defdelegate next_workspace(app), to: Workspaces
  defdelegate previous_workspace(app), to: Workspaces
  defdelegate focus_pane(app, id), to: Workspaces
  defdelegate rename_tab(app, ws_id, tab_id, name), to: Workspaces
  defdelegate rename_workspace(app, ws_id, name), to: Workspaces
  defdelegate rename_pane(app, id, name), to: Workspaces

  # --- helpers ---

  # the driver's pane area, at least 1x1 so a spawn never asks for an empty pty
  defp area(size, ui, tabs_count) do
    r = Frame.regions(size, ui, tabs_count).panes
    %{r | w: max(r.w, 1), h: max(r.h, 1)}
  end

  @doc false
  # `session.area` from `session.size` and the ui (also used by `App.Chrome`)
  # (also after a tab-count change: new_tab, drop_tab, `Workspaces.activate/2`); unchanged
  # when the area is
  def reframe(app) do
    n = if w = ws(app), do: length(w.tabs), else: 2

    case area(app.session.size, app.ui, n) do
      same when same == app.session.area -> app
      area -> put_in(app.session.area, area)
    end
  end

  defp ws(%{session: s}), do: Enum.find(s.workspaces, &(&1.id == s.active_workspace))

  defp put_ws(app, ws) do
    update_in(app.session.workspaces, fn l ->
      Enum.map(l, &if(&1.id == ws.id, do: ws, else: &1))
    end)
  end

  defp tab(app),
    do:
      (
        w = ws(app)
        Enum.find(w.tabs, &(&1.id == w.active_tab))
      )

  defp layout(app), do: tab(app).layout

  defp put_layout(app, l) do
    w = ws(app)

    put_ws(app, %{
      w
      | tabs: Enum.map(w.tabs, &if(&1.id == w.active_tab, do: %{&1 | layout: l}, else: &1))
    })
  end

  defp sync(app), do: put_in(app.focus.pane, layout(app).focus)

  defp unzoom(app), do: put_zoom(app, nil)

  # an absent key is no zoom, so clearing one that was never set changes nothing
  defp put_zoom(app, zoom) do
    w = ws(app)
    set = &if(zoom == nil, do: Map.delete(&1, :zoom), else: Map.put(&1, :zoom, zoom))
    put_ws(app, %{w | tabs: Enum.map(w.tabs, &if(&1.id == w.active_tab, do: set.(&1), else: &1))})
  end

  defp set_focus(app, id), do: app |> put_layout(Layout.focus(layout(app), id)) |> sync()

  defp take_id(app), do: {app.session.next_id, update_in(app.session.next_id, &(&1 + 1))}

  defp take_tab_id(app),
    do: {app.session.next_tab_id, update_in(app.session.next_tab_id, &(&1 + 1))}

  @doc false
  # a new tab's default name: the first number from the tab count up that no tab has
  # (also the new-tab prompt's prefill)
  @spec tab_name([map]) :: binary
  def tab_name(tabs) do
    names = MapSet.new(tabs, & &1.name)

    Stream.iterate(length(tabs) + 1, &(&1 + 1))
    |> Stream.map(&Integer.to_string/1)
    |> Enum.find(&(&1 not in names))
  end

  defp step_tab(app, d) do
    ws = ws(app)
    i = Enum.find_index(ws.tabs, &(&1.id == ws.active_tab))
    n = length(ws.tabs)
    switch_tab(app, rem(i + d + n, n) + 1)
  end

  defp content_rects(app),
    do: Layout.rects(layout(app), app.session.area, Layout.opts(tab(app), app.ui))

  # `l` is `tab`'s layout, possibly not yet stored on it
  defp size_of(app, tab, l, id),
    do: Layout.size(l, app.session.area, Layout.opts(tab, app.ui), id)

  # Close pane `id` wherever it lives, clearing its tab's zoom; unknown ids are a no-op
  # (membership is checked first, so `Layout.close/2` never sees an id that is not here).
  defp close_pane_id(app, id) do
    tab = Enum.find(ws(app).tabs, &(id in Layout.pane_ids(&1.layout)))
    close_in(app, tab, id)
  end

  defp close_in(app, nil, _id), do: {app, []}

  defp close_in(app, tab, id) do
    case Layout.close(tab.layout, id) do
      {:ok, l} -> {sync(drop_meta(put_tab_layout(app, tab.id, l), [id])), [{:close, id}]}
      :last -> drop_tab(app, tab.id)
    end
  end

  defp put_tab_layout(app, tab_id, l) do
    w = ws(app)

    put_ws(app, %{
      w
      | tabs:
          Enum.map(
            w.tabs,
            &if(&1.id == tab_id, do: Map.delete(%{&1 | layout: l}, :zoom), else: &1)
          )
    })
  end

  defp drop_meta(app, ids), do: update_in(app.session.panes, &Map.drop(&1, ids))

  defp drop_tab(app, tab_id) do
    ws = ws(app)
    tab = Enum.find(ws.tabs, &(&1.id == tab_id))
    ids = Layout.pane_ids(tab.layout)
    idx = Enum.find_index(ws.tabs, &(&1.id == tab_id))
    tabs = List.delete_at(ws.tabs, idx)
    app = drop_meta(app, ids)
    closes = Enum.map(ids, &{:close, &1})

    case tabs do
      [] ->
        {id, app} = take_id(app)
        {tab_id, app} = take_tab_id(app)
        l = Layout.new(id)
        t = %{id: tab_id, name: "1", layout: l}
        app = put_ws(app, %{ws | tabs: [t], active_tab: t.id})
        app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
        app = reframe(app)
        {sync(app), closes ++ [{:spawn, id, size_of(app, t, l, id)}]}

      _ ->
        active =
          if ws.active_tab == tab_id,
            do: Enum.at(tabs, max(idx - 1, 0)).id,
            else: ws.active_tab

        {sync(reframe(put_ws(app, %{ws | tabs: tabs, active_tab: active}))), closes}
    end
  end
end
