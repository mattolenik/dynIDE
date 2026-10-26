defmodule DynideServer.Api.AgentViewTest do
  use ExUnit.Case, async: true

  alias DynideServer.Api.{AgentView, Spec}
  alias DynideServer.App.{Actions, Commands}

  defp app do
    {app, _} =
      Commands.split_pane(
        elem(Actions.init(%{cols: 80, rows: 24}), 0),
        1,
        :horizontal,
        0.5,
        false
      )

    app
  end

  defp label(app, id, agent, state \\ nil),
    do: update_in(app.session.panes[id], &Map.merge(&1, %{agent: agent, agent_state: state}))

  test "agent ids follow the layout and skip panes without an agent" do
    app = app()
    assert AgentView.agent_ids(app) == []
    assert AgentView.agent_ids(label(label(app, 2, "codex"), 1, "claude")) == [1, 2]
    assert AgentView.agent_ids(label(app, 2, "codex")) == [2]
  end

  test "a target is a pane id, else a unique label" do
    app = app() |> label(1, "claude") |> label(2, "codex")
    assert AgentView.resolve(app, "p2") == {:ok, 2}
    assert AgentView.resolve(app, "codex") == {:ok, 2}
    assert {:error, :not_found, _} = AgentView.resolve(app, "p9")
    assert {:error, :not_found, "no agent pi"} = AgentView.resolve(app, "pi")

    both = label(app, 2, "claude")
    assert {:error, :not_found, msg} = AgentView.resolve(both, "claude")
    assert msg =~ "p1, p2"
  end

  test "the agent object takes status from meta and hook facts from the row" do
    app = label(app(), 1, "claude", :done)
    facts = %{title: "✳ claude", stripped_title: "claude", cwd: "/w"}
    row = %{agent: "claude", state: :idle, skipped: true, hook_source: "claude-hooks"}
    info = AgentView.info(app, 1, facts, row)

    assert %{
             pane_id: "p1",
             agent: "claude",
             agent_status: "done",
             terminal_title: "✳ claude",
             terminal_title_stripped: "claude",
             cwd: "/w",
             screen_detection_skipped: true,
             hook_source: "claude-hooks"
           } = info

    json = %{"type" => "agent_info", "agent" => info |> JSON.encode!() |> JSON.decode!()}
    assert Spec.validate_result("agent.get", json) == :ok

    assert %{agent: nil, agent_status: "unknown", screen_detection_skipped: false, cwd: nil} =
             AgentView.info(app(), 2, nil, nil)

    assert AgentView.info(app, 9, nil, nil) == nil
  end
end
