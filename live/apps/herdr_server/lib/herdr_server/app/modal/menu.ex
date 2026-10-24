defmodule HerdrServer.App.Modal.Menu do
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
  `Split right`, `Split down`, `Close pane`; global `settings`, `keybinds`, `detach`
  (reload config lands with Task 9).
  """

  @behaviour HerdrServer.App.Modal.Kind

  alias HerdrScene.Scene.Node
  alias HerdrServer.App.{Actions, Modal, Workspaces}
  alias HerdrServer.App.Modal.{Confirm, Prompt, Settings}
  alias HerdrServer.App.Modal.Keybinds, as: KeybindsModal
  alias HerdrServer.Layout
  alias HerdrServer.View.Modal, as: V

  @spec open(map, :tab | :workspace | :pane | :global, term, %{x: integer, y: integer}) ::
          {map, [tuple]}
  def open(app, menu, target, at) do
    case items(app, menu, target) do
      [] ->
        {app, []}

      items ->
        modal = %{kind: :menu, menu: menu, target: target, at: at, selected: 0, items: items}
        {Modal.push(app, modal), []}
    end
  end

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
