defmodule HerdrServer.App.Reconcile do
  @moduledoc """
  Pure: makes an app agree with the live pane set `live` (`%{pane_id => kernel_id}`, the
  panes mapped in `Pane.Rows` whose kernel id the keeper still holds). Used by `App.Store`
  on restart from the mirror and when it restores `state_at_load` after a repeat failure.

    * Dropped (in the app, not live): removed from `session.panes` and every layout. A tab
      left empty is removed; if it was active, the nearest earlier tab (else the next)
      becomes active. A workspace left with no tab gets a fresh one-pane tab, like closing
      the last tab in `App.Actions` (effect `{:spawn, id, size}`), unless adopted panes
      fill it. Effect `{:close, id}`.
    * Adopted (live, not in the app): split into the active workspace's tab named
      "scratch" (created at the end of the tab list if missing; the active tab only
      changes when it was emptied). `next_id` stays above every adopted id. Effect
      `{:adopt, id}`: the pane is already in the keeper and mapped, only its
      `Pane.Server` may be missing.

  An open popup's pane (`App.Modal.Popup`) is kept while live, else its modal is dropped.

  Focus follows the active tab's layout focus (`Layout.close/2` moves it within the tab).
  """

  alias HerdrServer.App.Modal.Popup
  alias HerdrServer.Layout

  @meta %{title: nil, layout_gen: 0}

  @spec run(map(), %{pos_integer() => term()}) :: {map(), [tuple()]}
  def run(app, live) do
    {app, popup_fx, live} = popup(app, live)
    s = app.session
    dropped = for id <- Enum.sort(Map.keys(s.panes)), not Map.has_key?(live, id), do: id
    adopted = live |> Map.keys() |> Enum.reject(&Map.has_key?(s.panes, &1)) |> Enum.sort()

    {app, fx} =
      if dropped == [] and adopted == [], do: {app, []}, else: fix(app, dropped, adopted)

    {app, popup_fx ++ fx}
  end

  # an open popup's pane is not in `session.panes`: kept (and not adopted) while live, its
  # modal dropped when it is gone
  defp popup(app, live) do
    case Popup.find(app) do
      nil ->
        {app, [], live}

      %{pane: id} when is_map_key(live, id) ->
        {app, [], Map.delete(live, id)}

      %{pane: id} ->
        {app, fx} = Popup.exited(app, id)
        {app, fx, live}
    end
  end

  defp fix(app, dropped, adopted) do
    s = app.session
    panes = s.panes |> Map.drop(dropped) |> Map.merge(Map.new(adopted, &{&1, @meta}))
    next_id = Enum.max([s.next_id | Enum.map(adopted, &(&1 + 1))])
    s = %{s | panes: panes, next_id: next_id}

    {wss, {s, spawns}} =
      Enum.map_reduce(s.workspaces, {s, []}, fn ws, acc ->
        adopt = if ws.id == s.active_workspace, do: adopted, else: []
        {ws, acc} = ws |> drop(dropped) |> adopt(adopt, acc)
        ensure_tab(ws, acc)
      end)

    s = %{s | workspaces: wss}
    ws = Enum.find(wss, &(&1.id == s.active_workspace))
    focus = Enum.find(ws.tabs, &(&1.id == ws.active_tab)).layout.focus
    app = %{app | session: s, focus: %{app.focus | pane: focus}}
    {app, Enum.map(dropped, &{:close, &1}) ++ Enum.map(adopted, &{:adopt, &1}) ++ spawns}
  end

  defp drop(ws, dropped) do
    pairs = Enum.map(ws.tabs, &{&1, drop_tab(&1, dropped)})
    %{ws | tabs: for({_, t} <- pairs, t != nil, do: t), active_tab: pick(pairs, ws.active_tab)}
  end

  defp drop_tab(tab, dropped) do
    case Enum.split_with(Layout.pane_ids(tab.layout), &(&1 in dropped)) do
      {_, []} ->
        nil

      {gone, _kept} ->
        l =
          Enum.reduce(gone, tab.layout, fn id, l ->
            {:ok, l} = Layout.close(l, id)
            l
          end)

        %{tab | layout: l}
    end
  end

  # the active tab if it survived, else the nearest earlier survivor, else the next one
  defp pick(pairs, active) do
    i = Enum.find_index(pairs, fn {t, _} -> t.id == active end) || 0
    {before, rest} = Enum.split(pairs, i)

    case Enum.find(Enum.take(rest, 1) ++ Enum.reverse(before) ++ Enum.drop(rest, 1), &elem(&1, 1)) do
      {t, _} -> t.id
      nil -> nil
    end
  end

  defp adopt(ws, [], acc), do: {ws, acc}

  defp adopt(ws, ids, {s, spawns} = acc) do
    case Enum.find(ws.tabs, &(&1.name == "scratch")) do
      nil ->
        [first | rest] = ids
        {tab_id, s} = take_tab_id(s)
        tab = %{id: tab_id, name: "scratch", layout: splits(Layout.new(first), rest)}
        {%{ws | tabs: ws.tabs ++ [tab], active_tab: ws.active_tab || tab.id}, {s, spawns}}

      scratch ->
        tab = %{scratch | layout: splits(scratch.layout, ids)}
        {%{ws | tabs: Enum.map(ws.tabs, &if(&1.id == tab.id, do: tab, else: &1))}, acc}
    end
  end

  # tab ids come from the session counter, like `App.Actions` (never a closed tab's id)
  defp take_tab_id(s), do: {s.next_tab_id, %{s | next_tab_id: s.next_tab_id + 1}}

  # alternating directions keep repeated splits from getting thin
  defp splits(l, ids) do
    ids
    |> Enum.with_index()
    |> Enum.reduce(l, fn {id, i}, l ->
      Layout.split(l, l.focus, if(rem(i, 2) == 0, do: :horizontal, else: :vertical), id)
    end)
  end

  defp ensure_tab(%{tabs: []} = ws, {s, spawns}) do
    id = s.next_id
    {tab_id, s} = take_tab_id(s)
    tab = %{id: tab_id, name: "1", layout: Layout.new(id)}
    s = %{s | next_id: id + 1, panes: Map.put(s.panes, id, @meta)}
    spawn = {:spawn, id, %{cols: s.area.w, rows: s.area.h}}
    {%{ws | tabs: [tab], active_tab: tab_id}, {s, spawns ++ [spawn]}}
  end

  defp ensure_tab(ws, acc), do: {ws, acc}
end
