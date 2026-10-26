defmodule DynideServer.App.Alerts do
  @moduledoc """
  Pure: agent state transitions to protocol alerts (herdr `app/actions.rs`). To
  `:blocked` is `"<agent> needs attention"` (level `:attention`, sound `:request`);
  `:working | :blocked` to `:idle | :done` is `"<agent> finished"` (`:done`, sound
  `:done`); any other transition, or a pane no tab holds, is none. The body is
  `"<workspace> · <n>"` (n the workspace's 1-based position), plus `" · <tab>"` when the
  workspace has several tabs. The agent is the pane's `agent`, else `"agent"`.

  `notify/4` is the API's `notification.show`: an `:attention`, `:request` alert with a
  caller-given title, body and (optional) pane.

  Whom an alert reaches (active-tab suppression, toasts) is per client:
  `Client.Toasts`.
  """

  alias DynideServer.Layout

  @type alert :: %{
          kind: :notification,
          level: :attention | :done,
          title: binary,
          body: binary,
          pane: pos_integer | nil,
          sound: :request | :done
        }

  @spec notify(map, binary, binary | nil, pos_integer | nil) :: {map, [{:alert, alert}]}
  def notify(app, title, body, pane) do
    {app,
     [
       {:alert,
        %{
          kind: :notification,
          level: :attention,
          title: title,
          body: body || "",
          pane: pane,
          sound: :request
        }}
     ]}
  end

  @spec from_agent(map, pos_integer, atom | nil, atom) :: [alert]
  def from_agent(app, id, old, new) do
    case {kind(old, new), place(app, id)} do
      {nil, _} -> []
      {_, nil} -> []
      {{level, text, sound}, body} -> [alert(app, id, level, text, sound, body)]
    end
  end

  defp kind(old, :blocked) when old != :blocked, do: {:attention, "needs attention", :request}

  defp kind(old, new) when old in [:working, :blocked] and new in [:idle, :done],
    do: {:done, "finished", :done}

  defp kind(_old, _new), do: nil

  defp alert(app, id, level, text, sound, body) do
    agent = Map.get(app.session.panes[id] || %{}, :agent) || "agent"

    %{
      kind: :notification,
      level: level,
      title: "#{agent} #{text}",
      body: body,
      pane: id,
      sound: sound
    }
  end

  defp place(app, id) do
    app.session.workspaces
    |> Enum.with_index(1)
    |> Enum.find_value(fn {ws, n} ->
      tab = Enum.find(ws.tabs, &(id in Layout.pane_ids(&1.layout)))
      tab && "#{ws.name} · #{n}" <> if(length(ws.tabs) > 1, do: " · #{tab.name}", else: "")
    end)
  end
end
