defmodule DynideServer.App.AlertsTest do
  use ExUnit.Case, async: true

  alias DynideScene.Protocol
  alias DynideServer.App.{Actions, Alerts}
  alias DynideServer.ViewHelpers

  defp app, do: ViewHelpers.fresh(80, 24) |> agent(1, "pi")
  defp agent(app, id, name), do: put_in(app.session.panes[id][:agent], name)

  test "the transition table (herdr app/actions.rs)" do
    a = app()

    assert [
             %{
               kind: :notification,
               level: :attention,
               title: "pi needs attention",
               body: "1 · 1",
               pane: 1,
               sound: :request
             } = alert
           ] = Alerts.from_agent(a, 1, :working, :blocked)

    assert Protocol.validate_server_msg({:alert, alert}) == :ok

    for old <- [:working, :blocked], new <- [:idle, :done] do
      assert [%{level: :done, title: "pi finished", sound: :done}] =
               Alerts.from_agent(a, 1, old, new)
    end

    assert [%{level: :attention}] = Alerts.from_agent(a, 1, nil, :blocked)
    assert Alerts.from_agent(a, 1, :blocked, :blocked) == []
    assert Alerts.from_agent(a, 1, :idle, :working) == []
    assert Alerts.from_agent(a, 1, nil, :idle) == []
    assert Alerts.from_agent(a, 1, :idle, :done) == []
    assert Alerts.from_agent(a, 9, :working, :blocked) == []
  end

  test "the body names the tab only when the workspace has several; no agent name says agent" do
    a = app() |> ViewHelpers.new_tab() |> agent(2, nil)
    assert [%{body: "1 · 1 · 1"}] = Alerts.from_agent(a, 1, :working, :blocked)

    assert [%{title: "agent finished", body: "1 · 1 · 2"}] =
             Alerts.from_agent(a, 2, :working, :idle)
  end

  test "{:agent_state, id, state} stores the state and emits alert effects" do
    {a, []} = Actions.apply(app(), {:agent_state, 1, :working})
    assert a.session.panes[1].agent_state == :working
    {a, [{:alert, %{level: :attention, pane: 1}}]} = Actions.apply(a, {:agent_state, 1, :blocked})
    assert a.session.panes[1].agent_state == :blocked
    assert {^a, []} = Actions.apply(a, {:agent_state, 9, :blocked})
  end

  test "notify is an attention request alert; body defaults to empty and pane may be nil" do
    a = app()

    assert {^a,
            [
              {:alert,
               %{
                 kind: :notification,
                 level: :attention,
                 title: "t",
                 body: "",
                 pane: nil,
                 sound: :request
               } = alert}
            ]} =
             Alerts.notify(a, "t", nil, nil)

    assert Protocol.validate_server_msg({:alert, alert}) == :ok
    assert {_, [{:alert, %{body: "b", pane: 1}}]} = Alerts.notify(a, "t", "b", 1)
  end
end
