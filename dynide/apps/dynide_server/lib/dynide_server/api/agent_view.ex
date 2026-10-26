defmodule DynideServer.Api.AgentView do
  @moduledoc """
  Pure: agent targets and the `"agent"` object of `Api.Spec` (herdr's AgentInfo).

  The label and published status (`done` included) come from the session meta
  (`agent`, `agent_state`); the terminal title, cwd and hook facts from the pane's
  `Pane.Facts` rows, which the caller reads and passes in.
  """

  alias DynideServer.Api.{Ids, View}
  alias DynideServer.Layout

  @type app :: DynideServer.App.Actions.app()

  @doc "Panes with a detected agent, in workspace, tab and layout order."
  @spec agent_ids(app()) :: [pos_integer()]
  def agent_ids(app) do
    for ws <- app.session.workspaces,
        tab <- ws.tabs,
        id <- Layout.pane_ids(tab.layout),
        get_in(app.session.panes, [id, :agent]) != nil,
        do: id
  end

  @doc """
  A target is a pane id that exists, else the one pane whose agent label it is.
  """
  @spec resolve(app(), String.t()) :: {:ok, pos_integer()} | {:error, :not_found, String.t()}
  def resolve(app, target) do
    with {:ok, id} <- Ids.parse_pane(target),
         %{} <- View.pane(app, id) do
      {:ok, id}
    else
      _ -> by_label(app, target)
    end
  end

  defp by_label(app, target) do
    case Enum.filter(agent_ids(app), &(app.session.panes[&1].agent == target)) do
      [id] ->
        {:ok, id}

      [] ->
        {:error, :not_found, "no agent #{target}"}

      ids ->
        {:error, :not_found,
         "agent #{target} is ambiguous: #{Enum.map_join(ids, ", ", &Ids.pane/1)}"}
    end
  end

  @doc """
  The agent object for pane `id` (nil when no tab holds it). `facts` is
  `Pane.Facts.get(id)`, `row` is `Pane.Facts.agent(id)`; either may be nil.
  """
  @spec info(app(), pos_integer(), map() | nil, map() | nil) :: map() | nil
  def info(app, id, facts, row) do
    with %{} = pane <- View.pane(app, id) do
      meta = app.session.panes[id] || %{}
      facts = facts || %{}
      row = row || %{}

      %{
        pane_id: pane.pane_id,
        workspace_id: pane.workspace_id,
        tab_id: pane.tab_id,
        agent: meta[:agent],
        agent_status: Atom.to_string(meta[:agent_state] || :unknown),
        title: pane.title,
        terminal_title: facts[:title],
        terminal_title_stripped: facts[:stripped_title],
        focused: pane.focused,
        cwd: facts[:cwd],
        screen_detection_skipped: Map.get(row, :skipped, false),
        hook_source: row[:hook_source]
      }
    end
  end
end
