defmodule HerdrServer.Plugins.ContextTest do
  use ExUnit.Case, async: true

  alias HerdrServer.App.{Actions, Commands}
  alias HerdrServer.Plugins.Context

  defp two_panes do
    app = elem(Actions.init(%{cols: 80, rows: 24}), 0)
    elem(Commands.split_pane(app, 1, :horizontal, 0.5, true), 0)
  end

  test "a two-pane app focused on p2" do
    cwd_of = fn
      2 -> "/work/p2"
      _ -> nil
    end

    ctx = Context.build(two_panes(), nil, "keybinding", %{cwd_of: cwd_of})

    assert %{
             "workspace_id" => "w1",
             "tab_id" => "w1:t1",
             "focused_pane_id" => "p2",
             "focused_pane_cwd" => "/work/p2",
             "workspace_cwd" => "/work/p2",
             "invocation_source" => "keybinding",
             "correlation_id" => "keybinding"
           } = ctx

    assert is_binary(ctx["workspace_label"]) and is_binary(ctx["tab_label"])
    refute Map.has_key?(ctx, "clicked_url")
  end

  test "an explicit pane, no cwd falls back to the server cwd, overrides win" do
    ctx =
      Context.build(two_panes(), 1, "api", %{
        :cwd_of => fn _ -> nil end,
        "correlation_id" => "req-1",
        "clicked_url" => "https://x",
        "bogus" => 1
      })

    assert ctx["focused_pane_id"] == "p1"
    assert ctx["workspace_cwd"] == File.cwd!()
    refute Map.has_key?(ctx, "focused_pane_cwd")
    assert ctx["correlation_id"] == "req-1" and ctx["clicked_url"] == "https://x"
    refute Map.has_key?(ctx, "bogus")
  end

  test "the pane's agent and published status, omitted when none" do
    app = two_panes()
    no_cwd = %{cwd_of: fn _ -> nil end}
    refute Map.has_key?(Context.build(app, 2, "api", no_cwd), "focused_pane_agent")
    refute Map.has_key?(Context.build(app, 2, "api", no_cwd), "focused_pane_agent_status")

    app = update_in(app.session.panes[2], &Map.merge(&1, %{agent: "claude", agent_state: :done}))

    assert %{"focused_pane_agent" => "claude", "focused_pane_agent_status" => "done"} =
             Context.build(app, 2, "api", no_cwd)
  end

  test "no app yet: only the invocation fields" do
    assert Context.build(nil, nil, "startup", %{"correlation_id" => "plugin.startup"}) ==
             %{"invocation_source" => "startup", "correlation_id" => "plugin.startup"}
  end

  test "menu targets resolve to a pane" do
    app = two_panes()
    assert Context.target_pane(app, {:pane, 1}) == 1
    assert Context.target_pane(app, {:tab, 1}) == 2
    assert Context.target_pane(app, {:workspace, 1}) == 2
    assert Context.target_pane(app, {:global, nil}) == nil
    assert Context.target_pane(app, {:pane, 99}) == nil
  end

  test "an event's pane, else its tab, else only its ids" do
    app = two_panes()
    f = %{cwd_of: fn _ -> nil end}
    ev = %{"event" => "pane.focused", "pane_id" => "p1", "workspace_id" => "w1"}
    assert Context.for_event(app, ev, f)["focused_pane_id"] == "p1"

    ev = %{"event" => "tab.created", "tab_id" => "w1:t1", "workspace_id" => "w1"}
    assert Context.for_event(app, ev, f)["focused_pane_id"] == "p2"

    ev = %{"event" => "tab.closed", "tab_id" => "w1:t9", "workspace_id" => "w1"}

    assert Context.for_event(app, ev, f) == %{
             "workspace_id" => "w1",
             "tab_id" => "w1:t9",
             "invocation_source" => "api",
             "correlation_id" => "tab.closed"
           }
  end
end
