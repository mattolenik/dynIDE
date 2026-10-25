defmodule HerdrServer.App.Agents do
  @moduledoc """
  Pure: the published agent status in `session.panes[id].agent_state` (herdr
  `pane_agent_status` and `seen`). `status/4` turns a detected `:idle` after `:working`,
  `:blocked` or `:done` into `:done` (finished, not yet looked at) unless the pane is in
  the active tab of the active workspace; every other state is stored as detected.
  `seen/1` turns `:done` back into `:idle` for the active tab's panes; the Store runs it
  after every event.
  """

  alias HerdrServer.Layout

  @spec status(map, pos_integer, atom | nil, atom) :: atom
  def status(app, id, old, :idle) when old in [:working, :blocked, :done],
    do: if(id in active_panes(app), do: :idle, else: :done)

  def status(_app, _id, _old, new), do: new

  @spec seen(map) :: map
  def seen(app) do
    Enum.reduce(active_panes(app), app, fn id, app ->
      case app.session.panes do
        %{^id => %{agent_state: :done} = meta} ->
          put_in(app.session.panes[id], %{meta | agent_state: :idle})

        _ ->
          app
      end
    end)
  end

  defp active_panes(%{session: s}) do
    with %{} = ws <- Enum.find(s.workspaces, &(&1.id == s.active_workspace)),
         %{} = tab <- Enum.find(ws.tabs, &(&1.id == ws.active_tab)) do
      Layout.pane_ids(tab.layout)
    else
      _ -> []
    end
  end
end
