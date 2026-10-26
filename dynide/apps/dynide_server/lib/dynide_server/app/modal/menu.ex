defmodule DynideServer.App.Modal.Menu do
  @moduledoc """
  Context and global menus (`%{kind: :menu, menu: :tab | :workspace | :pane | :global,
  target, at: %{x, y}, selected: 0, items: [{id, label, {M, F, A}}]}`, inventory §5).

  Up / Down move the selection (wrapping), Enter runs the selected item, a click on
  `{:entry, id}` runs that one: `apply(m, f, [app | a])`, then the menu is gone (the
  item may open a modal of its own). Esc or a backdrop click close it. The node is a
  `:menu` region at `at` (`View.Modal.menu_rect/3`), no dim, one `:item {:entry, id}`
  per item with `props.selected`.

  Items (exact labels; items whose task has not landed are omitted): tab `New tab`,
  `Rename`, `Close`; workspace `Rename`, `Close`; pane `Rename pane`, `Clear pane name`
  (when named), `Swap with focused pane` (another pane of the same tab is focused),
  `Split right`, `Split down`, `Zoom`, `Send right-clicks to pane` (or `Use dynIDE
  right-click menu` once set, `right_click/3`), `Close pane`; global `settings`, `keybinds`,
  `reload config`, `detach`.

  `open_worktree/1` (the `open_worktree` binding) asks git for the active workspace's
  worktrees off the Store (`App.Worktrees`); `worktrees/2` then lists them (a `:workspace`
  menu near the top left, entries `{:entry, n}`): one already open in a workspace focuses
  it, another opens a workspace on it.
  """

  @behaviour DynideServer.App.Modal.Kind

  alias DynideScene.Scene.Node
  alias DynideServer.App.{Actions, Modal, Workspaces, Worktrees}
  alias DynideServer.App.Modal.{Confirm, Prompt, Settings}
  alias DynideServer.App.Modal.Keybinds, as: KeybindsModal
  alias DynideServer.Layout
  alias DynideServer.Plugins.Menu, as: PluginMenu
  alias DynideServer.View.Modal, as: V

  @spec open(map, :tab | :workspace | :pane | :global, term, %{x: integer, y: integer}) ::
          {map, [tuple]}
  def open(app, menu, target, at) do
    push(app, menu, target, at, with_plugins(items(app, menu, target), app, menu, target))
  end

  defp push(app, _menu, _target, _at, []), do: {app, []}

  defp push(app, menu, target, at, items) do
    modal = %{kind: :menu, menu: menu, target: target, at: at, selected: 0, items: items}
    {Modal.push(app, modal), []}
  end

  @spec open_worktree(map) :: {map, [tuple]}
  def open_worktree(app) do
    Worktrees.list(app, app.session.active_workspace)
  end

  @doc "Lists worktrees (`App.Worktrees.run(:list, _)` entries) to open or focus."
  @spec worktrees(map, [map]) :: {map, [tuple]}
  def worktrees(app, entries) do
    paths = Enum.map(entries, & &1.path)
    # the polled cwd: the live one is a kernel read (App.Worktrees.root_cwd/1, off the Store)
    cwds = for ws <- app.session.workspaces, do: {ws.id, ws[:cwd]}

    items =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        text = Enum.join(Enum.reject([e.label, e.branch && "(#{e.branch})"], &is_nil/1), " ")

        mfa =
          case Worktrees.owner(cwds, paths, e.path) do
            nil -> {Worktrees, :open, [e.path, e.label, true]}
            id -> {Workspaces, :switch_workspace_id, [id]}
          end

        {i, text, mfa}
      end)

    push(app, :workspace, nil, %{x: 2, y: 1}, items)
  end

  # M14: plugin actions follow a menu's own items (none for a target that is gone)
  defp with_plugins([], _app, _menu, _target), do: []
  defp with_plugins(items, app, menu, target), do: items ++ PluginMenu.items(app, menu, target)

  defp items(app, :tab, id) do
    if Enum.any?(ws(app).tabs, &(&1.id == id)),
      do: [
        {:new_tab, "New tab", {Prompt, :new_tab, []}},
        {:rename, "Rename", {Prompt, :rename_tab, [app.session.active_workspace, id]}},
        {:close, "Close", {Confirm, :close_tab, [app.session.active_workspace, id]}}
      ],
      else: []
  end

  defp items(app, :workspace, id) do
    if Enum.any?(app.session.workspaces, &(&1.id == id)),
      do: [
        {:rename, "Rename", {Prompt, :rename_workspace, [id]}},
        {:close, "Close", {Confirm, :close_workspace, [id]}}
      ],
      else: []
  end

  defp items(app, :pane, id) do
    case app.session.panes do
      %{^id => meta} ->
        named = Map.get(meta, :name) not in [nil, ""]

        [{:rename, "Rename pane", {Prompt, :rename_pane, [id]}}] ++
          if(named,
            do: [{:clear_name, "Clear pane name", {__MODULE__, :clear_name, [id]}}],
            else: []
          ) ++
          if(swappable?(app, id),
            do: [{:swap, "Swap with focused pane", {__MODULE__, :swap, [id]}}],
            else: []
          ) ++
          [
            {:split_right, "Split right", {__MODULE__, :split, [id, :horizontal]}},
            {:split_down, "Split down", {__MODULE__, :split, [id, :vertical]}},
            {:zoom, "Zoom", {__MODULE__, :zoom, [id]}},
            if(Map.get(meta, :right_click) == :pane,
              do:
                {:right_click, "Use dynIDE right-click menu",
                 {__MODULE__, :right_click, [id, :menu]}},
              else:
                {:right_click, "Send right-clicks to pane",
                 {__MODULE__, :right_click, [id, :pane]}}
            ),
            {:close, "Close pane", {Confirm, :close_pane, [id]}}
          ]

      _ ->
        []
    end
  end

  defp items(_app, :global, _),
    do: [
      {:settings, "settings", {Settings, :open, []}},
      {:keybinds, "keybinds", {KeybindsModal, :open, []}},
      {:reload_config, "reload config", {Actions, :reload_config, []}},
      {:detach, "detach", {Actions, :detach, []}}
    ]

  # --- item actions ---

  @spec clear_name(map, term) :: {map, [tuple]}
  def clear_name(app, id) do
    case app.session.panes do
      %{^id => meta} -> {put_in(app.session.panes[id], Map.delete(meta, :name)), []}
      _ -> {app, []}
    end
  end

  @doc """
  Where plain right-clicks on pane `id` go (herdr's per-pane `right_click_passthrough`):
  `:pane` sends them to a mouse-tracking program, `:menu` opens this menu. Session
  metadata, not persisted (as in herdr).
  """
  @spec right_click(map, term, :pane | :menu) :: {map, [tuple]}
  def right_click(app, id, target) do
    case app.session.panes do
      %{^id => meta} when target == :pane ->
        {put_in(app.session.panes[id], Map.put(meta, :right_click, :pane)), []}

      %{^id => meta} ->
        {put_in(app.session.panes[id], Map.delete(meta, :right_click)), []}

      _ ->
        {app, []}
    end
  end

  @doc "Swaps pane `id` with the focused pane of the same tab."
  @spec swap(map, term) :: {map, [tuple]}
  def swap(app, id) do
    if swappable?(app, id) do
      w = ws(app)

      tabs =
        Enum.map(
          w.tabs,
          &if(&1.id == w.active_tab,
            do: %{&1 | layout: Layout.swap(&1.layout, id, app.focus.pane)},
            else: &1
          )
        )

      {put_ws(app, %{w | tabs: tabs}), []}
    else
      {app, []}
    end
  end

  @doc "Focuses pane `id` and splits it."
  @spec split(map, term, :horizontal | :vertical) :: {map, [tuple]}
  def split(app, id, dir) do
    {app, []} = Workspaces.focus_pane(app, id)
    Actions.split(app, dir)
  end

  @doc "Focuses pane `id` and toggles the zoom (herdr's pane menu `Zoom`)."
  @spec zoom(map, term) :: {map, [tuple]}
  def zoom(app, id) do
    {app, []} = Workspaces.focus_pane(app, id)
    Actions.toggle_zoom(app)
  end

  defp swappable?(app, id) do
    w = ws(app)
    ids = Layout.pane_ids(Enum.find(w.tabs, &(&1.id == w.active_tab)).layout)
    id != app.focus.pane and id in ids and app.focus.pane in ids
  end

  # --- kind ---

  @impl true
  def key(m, {:key, %{key: k}}, _app) when k in [:up, :down] do
    n = length(m.items)
    {:keep, %{m | selected: rem(m.selected + if(k == :up, do: n - 1, else: 1), n)}}
  end

  def key(m, {:key, %{key: :enter}}, app), do: run(Enum.at(m.items, m.selected), app, m)
  def key(m, _ev, _app), do: {:keep, m}

  @impl true
  def chrome(m, [{:entry, id}], {:click, _}, app),
    do: run(Enum.find(m.items, &(elem(&1, 0) == id)), app, m)

  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(m, _app, size) do
    labels = Enum.map(m.items, &elem(&1, 1))

    entries =
      m.items
      |> Enum.with_index()
      |> Enum.map(fn {{id, label, _}, i} ->
        %Node{role: :item, id: {:entry, id}, text: label, props: %{selected: i == m.selected}}
      end)

    %Node{
      role: :menu,
      rect: V.menu_rect(m.at, labels, size),
      props: %{kind: m.menu, selected: m.selected},
      children: entries
    }
  end

  defp run(nil, _app, m), do: {:keep, m}

  defp run({_id, _label, {mod, f, a}}, app, _m) do
    {app, effects} = apply(mod, f, [app | a])
    {:close, app, effects}
  end

  defp ws(%{session: s}), do: Enum.find(s.workspaces, &(&1.id == s.active_workspace))

  defp put_ws(app, w),
    do:
      update_in(
        app.session.workspaces,
        &Enum.map(&1, fn x -> if x.id == w.id, do: w, else: x end)
      )
end
