defmodule DynideServer.App.Upgrade do
  @moduledoc """
  Brings an app from an older shape (the M7 mirror, a handoff carry or a `code_change/3`
  from before a struct grew fields) up to the current `Session`, `Focus` and `Ui` structs.

  Each struct gets its missing keys from the defaults. A key whose default is a plain map
  (`ui.sidebar`, `ui.theme`, `ui.toast`, `ui.sound`, ...) is merged key by key when the old
  value is a map, and replaced by the default when it is not (an M7 `theme: :default`).
  Missing keybinds become `Keybinds.default/0`. The session's id counters are raised above
  every existing workspace and tab id (`next_ids/1`). Pure; an upgraded app is a fixed point.
  """

  alias DynideServer.App.{Focus, Keybinds, Session, Ui}

  @spec app(map) :: map
  def app(%{} = app) do
    app
    |> Map.put(:session, counters(merge(%Session{}, Map.get(app, :session))))
    |> Map.put(:focus, merge(%Focus{}, Map.get(app, :focus)))
    |> Map.put(:ui, ui(merge(%Ui{}, Map.get(app, :ui))))
  end

  @doc "`{next_workspace_id, next_tab_id}` just above every workspace and tab id in `wss`."
  @spec next_ids([map]) :: {pos_integer, pos_integer}
  def next_ids(wss) do
    {Enum.max([0 | Enum.map(wss, & &1.id)]) + 1,
     Enum.max([0 | for(ws <- wss, t <- ws.tabs, do: t.id)]) + 1}
  end

  defp counters(%Session{} = s) do
    {w, t} = next_ids(s.workspaces)
    %{s | next_workspace_id: max(s.next_workspace_id, w), next_tab_id: max(s.next_tab_id, t)}
  end

  defp ui(%Ui{keybinds: nil} = ui), do: %{ui | keybinds: Keybinds.default()}
  defp ui(ui), do: ui

  defp merge(default, old) when is_map(old) do
    Map.new(Map.from_struct(default), fn {k, d} -> {k, field(d, Map.get(old, k, d))} end)
    |> then(&struct(default, &1))
  end

  defp merge(default, _not_a_map), do: default

  defp field(d, v) when is_map(d) and not is_struct(d) and is_map(v) and not is_struct(v),
    do: Map.merge(d, v)

  defp field(d, _v) when is_map(d) and not is_struct(d), do: d
  defp field(_d, v), do: v
end
