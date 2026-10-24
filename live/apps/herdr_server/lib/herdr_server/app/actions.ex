defmodule HerdrServer.App.Actions do
  @moduledoc """
  Pure input handling: `apply/2` turns a neutral `HerdrScene.Event` (plus the
  server-internal `{:pane_exited, id}` and `{:pane_title, id, title}`, which are never
  accepted from clients) into new app state and a list of effects. Effects are the only
  side-effect channel; this module does no I/O and sends no messages.

  Effects: `{:spawn, id, %{cols, rows}}`, `{:close, id}`, `{:key, id, event}`,
  `{:mouse, id, event}` (coordinates pane-relative), `{:paste, id, binary}`,
  `{:focus_report, id, boolean}`, `{:notice, %{level, text}}`, `{:detach}`.

  Ponytail: panes' `layout_gen` is not bumped here; the Store owns resize bookkeeping.
  """

  alias HerdrServer.App.{Focus, Keybinds, Session, Ui}
  alias HerdrServer.Layout

  @type app :: %{session: Session.t(), focus: Focus.t(), ui: Ui.t()}
  @type effect :: tuple()

  @spec init(%{cols: pos_integer(), rows: pos_integer()}) :: {app(), [effect()]}
  def init(%{cols: c, rows: r}) do
    area = %{x: 0, y: 0, w: c, h: max(r - 1, 1)}
    layout = Layout.new(1)

    session = %Session{
      workspaces: [
        %{
          id: 1,
          name: "1",
          tabs: [%{id: 1, name: "1", layout: layout}],
          active_tab: 1
        }
      ],
      active_workspace: 1,
      panes: %{1 => %{title: nil, layout_gen: 0}},
      next_id: 2,
      area: area
    }

    app = %{
      session: session,
      focus: %Focus{pane: 1},
      ui: %Ui{keybinds: Keybinds.default()}
    }

    {app, [{:spawn, 1, size_of(layout, area, 1)}]}
  end

  # --- events ---

  @spec apply(app(), tuple()) :: {app(), [effect()]}
  def apply(app, {:key, %{event: :release}}) when app.focus.mode != :terminal, do: {app, []}

  def apply(app, {:key, %{key: k, mods: m}} = event) do
    kb = app.ui.keybinds
    key = Keybinds.normalize(k, m)
    mode = app.focus.mode
    key_in(mode, app, event, key, Keybinds.lookup(kb, mode, key), Keybinds.prefix?(kb, key))
  end

  def apply(app, {:paste, bin}), do: to_focused(app, :paste, bin)

  def apply(app, {:focus, b}) when is_boolean(b), do: to_focused(app, :focus_report, b)

  def apply(app, {:resize, %{cols: c, rows: r}}),
    do: {put_in(app.session.area, %{x: 0, y: 0, w: c, h: max(r - 1, 1)}), []}

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

  def apply(app, {:pane_exited, id}), do: close_pane_id(app, id)

  def apply(app, {:pane_title, id, title}) do
    case app.session.panes do
      %{^id => meta} -> {put_in(app.session.panes[id], %{meta | title: title}), []}
      _ -> {app, []}
    end
  end

  def apply(app, _other), do: {app, []}

  # key_in(mode, app, event, key, bound_mfa | nil, prefix_key?)
  defp key_in(:terminal, app, {:key, %{event: :release}}, _, bound, prefix?)
       when bound != nil or prefix?,
       do: {app, []}

  defp key_in(:terminal, app, _, _, _, true), do: {put_mode(app, :prefix), []}
  defp key_in(:terminal, app, _, _, bound, _) when bound != nil, do: call(app, bound)
  defp key_in(:terminal, app, event, _, _, _), do: to_focused(app, :key, event)

  defp key_in(:prefix, app, _, _, bound, _) when bound != nil,
    do: call(put_mode(app, :terminal), bound)

  defp key_in(:prefix, app, event, _, _, true),
    do: to_focused(put_mode(app, :terminal), :key, event)

  defp key_in(:prefix, app, _, _, _, _), do: {put_mode(app, :terminal), []}
  defp key_in(:resize, app, _, _, bound, _) when bound != nil, do: call(app, bound)
  defp key_in(:resize, app, _, _, _, _), do: {app, []}

  defp call(app, {m, f, a}), do: Kernel.apply(m, f, [app | a])

  defp to_focused(%{focus: %{pane: nil}} = app, _, _), do: {app, []}
  defp to_focused(app, tag, payload), do: {app, [{tag, app.focus.pane, payload}]}

  defp put_mode(app, mode), do: put_in(app.focus.mode, mode)

  defp rel({:mouse, m}, r), do: {:mouse, %{m | x: m.x - r.x, y: m.y - r.y}}

  defp inside?(r, x, y), do: x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

  # --- actions ---

  @spec new_tab(app()) :: {app(), [effect()]}
  def new_tab(app) do
    {id, app} = take_id(app)
    ws = ws(app)
    tab_id = next_tab_id(ws)
    layout = Layout.new(id)
    tab = %{id: tab_id, name: Integer.to_string(tab_id), layout: layout}
    app = put_ws(app, %{ws | tabs: ws.tabs ++ [tab], active_tab: tab_id})
    app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
    {sync(app), [{:spawn, id, size_of(layout, app.session.area, id)}]}
  end

  @spec close_tab(app()) :: {app(), [effect()]}
  def close_tab(app), do: drop_tab(app, ws(app).active_tab)

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

  @spec split(app(), :horizontal | :vertical) :: {app(), [effect()]}
  def split(app, dir) do
    with %{} = l <- layout(app), focus when not is_nil(focus) <- l.focus do
      {id, app} = take_id(app)
      l = Layout.split(l, focus, dir, id)
      app = app |> put_layout(l) |> sync()
      app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
      {app, [{:spawn, id, size_of(l, app.session.area, id)}]}
    else
      _ -> {app, []}
    end
  end

  @spec close_pane(app()) :: {app(), [effect()]}
  def close_pane(app), do: close_pane_id(app, app.focus.pane)

  @spec focus_dir(app(), Layout.nav()) :: {app(), [effect()]}
  def focus_dir(app, nav) do
    l = layout(app)

    case Layout.find_in_direction(l, app.session.area, l.focus, nav) do
      nil -> {app, []}
      id -> {set_focus(app, id), []}
    end
  end

  @spec cycle(app(), :next | :previous) :: {app(), [effect()]}
  def cycle(app, which) do
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
    l = layout(app)

    case Layout.find_in_direction(l, app.session.area, l.focus, nav) do
      nil -> {app, []}
      id -> {put_layout(app, Layout.swap(l, l.focus, id)), []}
    end
  end

  @spec resize_dir(app(), Layout.nav(), float()) :: {app(), [effect()]}
  def resize_dir(app, nav, delta),
    do: {put_layout(app, Layout.resize(layout(app), app.session.area, nav, delta)), []}

  @spec enter_mode(app(), :terminal | :prefix | :resize) :: {app(), [effect()]}
  def enter_mode(app, mode), do: {put_mode(app, mode), []}

  @spec detach(app()) :: {app(), [effect()]}
  def detach(app), do: {app, [{:notice, %{level: :info, text: "detach not implemented"}}]}

  # --- helpers ---

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

  defp set_focus(app, id), do: app |> put_layout(Layout.focus(layout(app), id)) |> sync()

  defp take_id(app), do: {app.session.next_id, update_in(app.session.next_id, &(&1 + 1))}

  defp next_tab_id(ws), do: Enum.max([0 | Enum.map(ws.tabs, & &1.id)]) + 1

  defp step_tab(app, d) do
    ws = ws(app)
    i = Enum.find_index(ws.tabs, &(&1.id == ws.active_tab))
    n = length(ws.tabs)
    switch_tab(app, rem(i + d + n, n) + 1)
  end

  defp content_rects(app) do
    l = layout(app)
    area = app.session.area
    Layout.borders(Layout.panes(l, area), area)
  end

  defp size_of(l, area, id) do
    %{rect: r} = Enum.find(Layout.borders(Layout.panes(l, area), area), &(&1.id == id))
    %{cols: r.w, rows: r.h}
  end

  # Close pane `id` wherever it lives; unknown ids are a no-op (Layout.close/2 returns
  # :last for them too, so membership is checked first).
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
      | tabs: Enum.map(w.tabs, &if(&1.id == tab_id, do: %{&1 | layout: l}, else: &1))
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
        l = Layout.new(id)
        t = %{id: next_tab_id(%{tabs: []}), name: "1", layout: l}
        app = put_ws(app, %{ws | tabs: [t], active_tab: t.id})
        app = put_in(app.session.panes[id], %{title: nil, layout_gen: 0})
        {sync(app), closes ++ [{:spawn, id, size_of(l, app.session.area, id)}]}

      _ ->
        active =
          if ws.active_tab == tab_id,
            do: Enum.at(tabs, max(idx - 1, 0)).id,
            else: ws.active_tab

        {sync(put_ws(app, %{ws | tabs: tabs, active_tab: active})), closes}
    end
  end
end
