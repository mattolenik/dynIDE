defmodule HerdrServer.Detect.TrackerTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Detect.Engine.Detection
  alias HerdrServer.Detect.Tracker

  @osc {"", ""}

  defp acquired(label \\ "claude", now \\ 0) do
    {t, _} = Tracker.job(Tracker.new(grace_ms: 0), {label, 42}, false, now, @osc)
    t
  end

  defp det(state, flags \\ []), do: struct!(%Detection{state: state}, flags)

  defp screen(t, d, now, activity \\ make_ref()), do: Tracker.screen(t, d, activity, now)

  defp working(now \\ 0) do
    {t, [{:state, :working}]} = screen(acquired(), det(:working), now)
    t
  end

  defp hook(state, seq \\ 1, agent \\ "claude"),
    do: %{source: "claude-hooks", agent: agent, state: state, seq: seq}

  test "new agent publishes agent and waits out the 3 s grace" do
    t = Tracker.new()
    {t, effects} = Tracker.job(t, {"claude", 42}, false, 1_000, @osc)
    assert effects == [{:agent, "claude"}]
    assert t.agent == "claude" and t.agent_pid == 42 and t.state == :unknown
    assert t.grace_until == 4_000 and t.osc_stale == nil
    refute Tracker.scan?(t, 1, 3_999)
    assert Tracker.scan?(t, 1, 4_000)
    assert {_, [{:state, :idle}]} = Tracker.screen(t, det(:idle), 1, 4_000)
  end

  test "replacement agent ignores the previous agent's osc title until it changes" do
    {t, _} = Tracker.job(acquired("claude"), {"codex", 7}, false, 0, {"claude title", "3"})
    assert t.osc_stale == {"claude title", "3"}
    assert Tracker.osc_input(t, {"claude title", "3"}) == {"", ""}
    assert Tracker.osc_input(t, {"codex title", "3"}) == {"codex title", ""}
    assert Tracker.osc_input(t, {"codex title", "4"}) == {"codex title", "4"}
    assert Tracker.osc_input(acquired(), {"x", "1"}) == {"x", "1"}
  end

  test "agent exit publishes idle then clears the agent after 6 misses" do
    t = working()
    {t, []} = Tracker.job(t, nil, true, 100, @osc)
    assert t.exited and t.misses == 1
    assert Tracker.scan?(t, :same, 100)
    {t, effects} = Tracker.screen(t, :exited, :same, 100)
    assert effects == [{:state, :idle}] and t.visible.idle

    t =
      Enum.reduce(2..5, t, fn i, t ->
        {t, []} = Tracker.job(t, nil, true, i * 100, @osc)
        t
      end)

    assert t.agent == "claude"
    {t, effects} = Tracker.job(t, nil, true, 600, @osc)
    assert effects == [{:agent, nil}, {:state, :unknown}]
    assert t.agent == nil and t.misses == 0 and not t.exited
  end

  test "working to plain idle holds for 3 confirmations" do
    t = working()
    {t, []} = screen(t, det(:idle), 100)
    assert Tracker.next_ms(t, 100) == 100
    {t, []} = screen(t, det(:idle), 200)
    {t, []} = screen(t, det(:idle), 300)
    {t, [{:state, :idle}]} = screen(t, det(:idle), 400)
    assert t.pending_idle == nil and Tracker.next_ms(t, 400) == nil
  end

  test "working to plain idle publishes after 700 ms" do
    t = working()
    {t, []} = screen(t, det(:idle), 100)
    {t, []} = screen(t, det(:idle), 799)
    {_, [{:state, :idle}]} = screen(t, det(:idle), 800)
  end

  test "working to visible idle publishes at once" do
    {t, [{:state, :idle}]} = screen(working(), det(:idle, visible_idle: true), 100)
    assert t.visible.idle
  end

  test "skip_state_update keeps the state" do
    {t, []} = screen(working(), det(:idle, skip_state_update: true), 100)
    assert t.state == :working and t.pending_idle == nil
  end

  test "unchanged idle activity does not rescan" do
    {t, [{:state, :idle}]} = Tracker.screen(acquired(), det(:idle), 5, 0)
    refute Tracker.scan?(t, 5, 10_000)
    assert Tracker.scan?(t, 6, 10_000)
    refute Tracker.scan?(Tracker.new(), 6, 0)
  end

  test "hook state wins over screen idle" do
    {t, [{:state, :working}]} = Tracker.report(acquired(), hook(:working))
    {t, []} = screen(t, det(:idle, visible_idle: true), 100)
    assert t.state == :idle and Tracker.effective(t) == :working
  end

  test "visible blocker overrides a working hook" do
    {t, _} = Tracker.report(acquired(), hook(:working))
    {t, [{:state, :blocked}]} = screen(t, det(:blocked, visible_blocker: true), 100)
    assert Tracker.effective(t) == :blocked
    # Stable blocker refreshes every 800 ms even without new activity.
    refute Tracker.scan?(t, t.scanned, 899)
    assert Tracker.scan?(t, t.scanned, 900)
  end

  test "stale hook seq is ignored" do
    {t, _} = Tracker.report(acquired(), hook(:working, 5))
    assert {^t, []} = Tracker.report(t, hook(:idle, 5))
    assert {^t, []} = Tracker.report(t, hook(:idle, 4))
    {t, [{:state, :idle}]} = Tracker.report(t, hook(:idle, 6))
    assert t.hook.seq == 6
  end

  test "hook for another agent is ignored" do
    t = acquired("claude")
    assert {^t, []} = Tracker.report(t, hook(:working, 1, "codex"))
    {t, effects} = Tracker.report(Tracker.new(), hook(:working, 1, "codex"))
    assert effects == [{:agent, "codex"}, {:state, :working}] and t.agent == "codex"
  end

  test "release clears the hook" do
    {t, _} = Tracker.report(acquired(), hook(:working))
    assert {^t, []} = Tracker.release(t, "other", "claude")
    {t, [{:state, :unknown}]} = Tracker.release(t, "claude-hooks", "claude")
    assert t.hook == nil
  end

  test "probe schedule after a pgid change" do
    t = Tracker.new()
    {t, true} = Tracker.pgid(t, 100, 0)

    {t, probes} =
      Enum.reduce(100..9_900//100, {t, []}, fn now, {t, acc} ->
        {t, probe?} = Tracker.pgid(t, 100, now)
        {t, if(probe?, do: [now | acc], else: acc)}
      end)

    assert Enum.reverse(probes) == [500, 1_000, 1_500, 3_500, 5_500, 7_500]
    assert {_, true} = Tracker.pgid(t, nil, 10_000)

    t = %{t | agent: "claude"}
    assert {_, false} = Tracker.pgid(t, 100, 12_499)
    {t, true} = Tracker.pgid(t, 100, 12_500)
    assert {_, true} = Tracker.pgid(t, 100, 17_500)
  end
end
