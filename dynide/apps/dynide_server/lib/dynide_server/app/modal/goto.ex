defmodule DynideServer.App.Modal.Goto do
  @moduledoc """
  The Go to navigator (`prefix+g`, `goto`): `%{kind: :goto, field: TextField.t(), filter,
  selected}`. One row per pane of every workspace, grouped by workspace in sidebar order
  (tabs, then the layout's preorder), text `"<workspace> · <tab> · <pane>"` where the pane
  is its name, else its title, else `"terminal"`. Typing edits the filter field, a
  case-insensitive substring match over the row text. Up / Down move the selection
  (wrapping), Enter or a click on `[:list, {:pane, id}]` focuses that pane in any
  workspace (`Workspaces.focus_pane/2`) and closes; Esc or a backdrop click close.

  Tab / Shift+Tab cycle the status `filter` (`nil` -> `:blocked` -> `:working` -> `:idle`
  -> `:done` -> `nil`, a missing key reads `nil`): only panes whose `meta.agent_state`
  equals it are listed (nil or unknown states never match). Unlike herdr, which clears
  the query on a filter key, the typed text is kept and both apply; the selection resets
  to the first row. With `ui.agent_panel_sort` `:priority` rows sort by attention
  (`View.Sidebar.priority/1`), stable within one priority.

  Node: a `:modal` `kind: :goto` panel (72x20): title `"go to"`, the `:input`, a `:list`
  of choice items `{:pane, id}` (the title `"go to / <filter>"` under a filter) (`current` on the focused pane, a muted `:empty` text when
  nothing matches), then a muted `:hint`.
  """

  @behaviour DynideServer.App.Modal.Kind

  alias DynideServer.App.{Modal, Workspaces}
  alias DynideServer.App.Modal.TextField
  alias DynideServer.Layout
  alias DynideServer.View.Modal, as: V
  alias DynideServer.View.Sidebar

  @filters [nil, :blocked, :working, :idle, :done]

  @hint "type to filter · tab filter · move ↑↓ · go enter · close esc"

  @spec open(map) :: {map, [tuple]}
  def open(app),
    do: {Modal.push(app, %{kind: :goto, field: TextField.new(""), selected: 0, filter: nil}), []}

  @doc """
  The rows `{pane_id, text}` matching `query` (case-insensitive substring) and the
  status `filter` (`nil` for all), in attention order under `ui.agent_panel_sort`
  `:priority`.
  """
  @spec rows(map, binary, atom | nil) :: [{term, binary}]
  def rows(app, query, filter \\ nil) do
    q = String.downcase(query)

    rows =
      for ws <- app.session.workspaces,
          tab <- ws.tabs,
          id <- Layout.pane_ids(tab.layout),
          meta = Map.get(app.session.panes, id) || %{},
          filter == nil or meta[:agent_state] == filter,
          text = Enum.join([ws.name, tab.name, pane(meta)], " · "),
          String.contains?(String.downcase(text), q),
          do: {id, text, meta[:agent_state]}

    rows =
      if app.ui.agent_panel_sort == :priority,
        do: Enum.sort_by(rows, &(-Sidebar.priority(elem(&1, 2)))),
        else: rows

    Enum.map(rows, fn {id, text, _} -> {id, text} end)
  end

  defp found(m, app), do: rows(app, m.field.text, Map.get(m, :filter))

  defp pane(meta) do
    Enum.find([meta[:name], meta[:title]], "terminal", &(&1 not in [nil, ""]))
  end

  # --- kind ---

  @impl true
  def key(m, {:key, %{key: :tab, mods: mods}}, _app) when mods in [[], [:shift]] do
    d = if mods == [], do: 1, else: -1
    i = Enum.find_index(@filters, &(&1 == Map.get(m, :filter))) || 0
    {:keep, Map.merge(m, %{filter: Enum.at(@filters, Integer.mod(i + d, 5)), selected: 0})}
  end

  def key(m, {:key, %{key: k, mods: []}}, app) when k in [:up, :down] do
    n = length(found(m, app))
    d = if k == :up, do: -1, else: 1
    {:keep, %{m | selected: if(n == 0, do: 0, else: Integer.mod(clamp(m, n) + d, n))}}
  end

  def key(m, {:key, %{key: :enter, mods: []}}, app) do
    found = found(m, app)

    case Enum.at(found, clamp(m, length(found))) do
      nil -> {:keep, m}
      {id, _} -> go(app, id)
    end
  end

  def key(m, ev, _app) do
    case TextField.key(m.field, ev) do
      {:ok, f} -> {:keep, %{m | field: f, selected: 0}}
      :ignore -> {:keep, m}
    end
  end

  @impl true
  def chrome(_m, [:list, {:pane, id}], {:click, _}, app), do: go(app, id)
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(m, app, size) do
    rect = V.panel(size, 72, 20)
    rows = max(V.inner_rows(rect) - 4, 0)
    found = found(m, app)
    sel = clamp(m, length(found))

    items =
      case found do
        [] ->
          [V.text(:empty, "no matching panes", :muted)]

        _ ->
          found
          |> Enum.with_index()
          |> Enum.map(fn {{id, text}, i} ->
            V.choice({:pane, id}, text, i == sel, id == app.focus.pane)
          end)
      end

    V.modal(:goto, rect, :default, [
      V.title(Enum.join(["go to" | List.wrap(Map.get(m, :filter))], " / ")),
      V.input(m.field, rect.w),
      V.list(items, rows, V.window(sel, length(items), rows)),
      V.text(:hint, @hint, :muted)
    ])
  end

  # panes may close while the modal is open: the selection stays on the last row
  defp clamp(m, n), do: min(m.selected, max(n - 1, 0))

  defp go(app, id) do
    {app, effects} = Workspaces.focus_pane(app, id)
    {:close, app, effects}
  end
end
