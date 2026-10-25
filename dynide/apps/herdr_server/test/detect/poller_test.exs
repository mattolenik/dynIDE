defmodule HerdrServer.Detect.PollerTest do
  # Detect.Poller over the fake kernel: a test-owned poller (the app's is stopped).
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Detect.Poller
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Mirror
  alias HerdrServer.Pane.{Facts, Rows}

  @size %{cols: 120, rows: 40}
  @blocked "\r\n Run a dynamic workflow?\r\n esc to cancel\r\n"
  @claude %{pgid: 4242, shell: false, processes: [%{pid: 4242, name: "claude", argv: ["claude"]}]}

  defmodule Boom do
    def detect(_entry, _input), do: raise("engine boom")
  end

  setup do
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Poller)
    reset()

    on_exit(fn ->
      reset()
      Supervisor.restart_child(HerdrServer.Supervisor, Poller)
    end)

    attach()
    assert eventually(fn -> Facts.get(1) != nil end)
    :ok
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

    Store.reset()
    Enum.each(Facts.agent_ids(), &Facts.delete_agent/1)
  end

  defp attach do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: @size,
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, GenServer.call(Protocol.endpoint(), {:attach, info})})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, {:ok, _session, _}}
  end

  defp poller(opts) do
    start_supervised!({Poller, [name: :test_poller, grace_ms: 0] ++ opts})
  end

  defp res(id), do: elem(Fake.Keeper.lookup(Rows.kernel_id(id)), 1)

  defp eventually(fun, ms \\ 2000) do
    Enum.any?(1..div(ms, 20), fn _ -> fun.() || (Process.sleep(20) && false) end)
  end

  defp agent_state(id), do: Store.snapshot().session.panes[id][:agent_state]

  test "a claude job showing a blocked dialog publishes blocked" do
    poller([])
    :ok = Fake.Pty.set_foreground(res(1).pty, @claude)
    Fake.Pty.output(res(1).pty, @blocked)

    assert eventually(fn -> match?(%{state: :blocked}, Facts.agent(1)) end, 4000)
    assert %{agent: "claude", skipped: false, hook_source: nil} = Facts.agent(1)
    assert eventually(fn -> agent_state(1) == :blocked end)
  end

  test "scrolled viewport does not change the detection source" do
    p = poller([])
    %{vt: vt, pty: pty} = res(1)
    # the blocked dialog only in the scrollback, the viewport scrolled onto it
    :ok = Fake.Vt.set_history(vt, ["old", " Run a dynamic workflow?", " esc to cancel"])
    :ok = Fake.Vt.scroll_to(vt, 0)
    :ok = Fake.Pty.set_foreground(pty, @claude)
    Fake.Pty.output(pty, "$ ")

    assert eventually(fn ->
             match?(%{scanned: n} when n != nil, :sys.get_state(p).trackers[1])
           end)

    assert %{agent: "claude", state: state} = Facts.agent(1)
    refute state == :blocked

    # still scrolled: the bottom rows are what is read
    Fake.Pty.output(pty, @blocked)
    assert eventually(fn -> match?(%{state: :blocked}, Facts.agent(1)) end)
    assert Fake.Vt.scrollbar(vt).offset == 0
  end

  test "closed pane drops its tracker and facts row" do
    p = poller([])
    :ok = Store.run({Actions, :split, [:horizontal]}, @size)
    assert eventually(fn -> Facts.agent(2) != nil end)
    assert eventually(fn -> Map.has_key?(:sys.get_state(p).trackers, 2) end)

    Store.event_async({:pane_exited, 2})
    assert eventually(fn -> not Map.has_key?(:sys.get_state(p).trackers, 2) end)
    assert Facts.agent(2) == nil
    assert Facts.agent(1) != nil
  end

  test "a malformed hook neither crashes the poller nor answers ok when it fails" do
    p = poller([])
    assert eventually(fn -> Facts.agent(1) != nil end)

    # no source: kept, published with a nil hook_source
    assert :ok = Poller.report(1, %{agent: "claude", state: :working, seq: 1}, p)
    assert %{agent: "claude", hook_source: nil, skipped: false} = Facts.agent(1)
    # no agent: Tracker.report has no clause, the Guard catches it
    assert {:error, :failed} = Poller.report(1, %{}, p)
    assert Process.alive?(p)
  end

  test "an idle telemetry window logs nothing" do
    # the poller sees panes through the Mirror (20 ms behind the Store)
    assert eventually(fn ->
             Map.has_key?((Mirror.app() || %{session: %{panes: %{}}}).session.panes, 1)
           end)

    p = poller(interval_ms: 3_600_000, window_ms: 0)
    # the first tick probes the new pane
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ = send(p, :tick)
        :sys.get_state(p)
      end)

    assert log =~ "detect_tick"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ = send(p, :tick)
        :sys.get_state(p)
      end)

    refute log =~ "detect_tick"
  end

  test "a new poller drops rows a previous one left for closed panes" do
    Facts.put_agent(77, %{
      agent: "claude",
      state: :idle,
      visible: %{},
      hook_source: nil,
      skipped: false,
      updated_ms: 0
    })

    poller([])
    assert eventually(fn -> Facts.agent(77) == nil end)
  end

  test "a new poller resumes a previous one's label, so the miss rule can clear it" do
    Facts.put_agent(1, %{
      agent: "claude",
      state: :working,
      visible: %{},
      hook_source: nil,
      skipped: false,
      updated_ms: 0
    })

    p = poller([])
    assert %{agent: "claude", state: :working} = :sys.get_state(p).trackers[1]
    # the pane's job is its shell: each probe is a miss toward the clear
    assert eventually(fn -> :sys.get_state(p).trackers[1].misses >= 1 end)
  end

  test "an agent that is the pane's root process is detected" do
    poller([])
    :ok = Fake.Pty.set_foreground(res(1).pty, %{@claude | shell: true})
    assert eventually(fn -> match?(%{agent: "claude"}, Facts.agent(1)) end, 4000)
  end

  test "at most 4 scans per tick with 15 active panes" do
    for _ <- 2..15, do: :ok = Store.run({Actions, :new_tab, []}, @size)
    assert eventually(fn -> Enum.all?(1..15, &(Facts.get(&1) != nil)) end)
    assert eventually(fn -> map_size(Mirror.app().session.panes) == 15 end)
    p = poller(interval_ms: 3_600_000)
    for id <- 1..15, do: :ok = Poller.force_agent(id, "claude", p)

    # ticks driven by hand; every pane has new output before each
    for round <- 1..4 do
      for id <- 1..15, do: Fake.Pty.output(res(id).pty, "line #{round}\r\n")
      for id <- 1..15, do: _ = Fake.Pty.activity(res(id).pty)
      send(p, :tick)
      assert %{last: %{scans: 4, probes: probes}} = :sys.get_state(p)
      # 15 fresh panes all want a probe: 4 per tick, the rest stay due
      if round == 1, do: assert(probes == 4), else: assert(probes <= 4)
    end

    # the round robin reached every pane
    trackers = :sys.get_state(p).trackers
    assert Enum.count(trackers, fn {_, t} -> t.scanned != nil end) == 15
  end

  test "a raising Engine (Guard failure) skips the pane and the poller lives" do
    p = poller(engine: Boom)
    :ok = Fake.Pty.set_foreground(res(1).pty, @claude)
    Fake.Pty.output(res(1).pty, @blocked)

    assert eventually(fn -> match?(%{agent: "claude"}, Facts.agent(1)) end)
    Process.sleep(700)
    assert Process.alive?(p)
    assert %{state: :unknown} = Facts.agent(1)
    assert :sys.get_state(p).trackers[1].scanned == nil
  end

  test "detect_now reads the bottom rows; report and release drive the hook" do
    p = poller([])
    :ok = Fake.Pty.set_foreground(res(1).pty, @claude)
    Fake.Pty.output(res(1).pty, @blocked)
    assert eventually(fn -> match?(%{agent: "claude"}, Facts.agent(1)) end)

    assert {:ok, %{agent: "claude", entry: %{agent: "claude"}, input: input}} =
             Poller.detect_now(1, p)

    assert input.screen =~ "esc to cancel"
    assert {:error, :not_found} = Poller.detect_now(99, p)

    hook = %{source: "hooks", agent: "claude", state: :working, seq: 1}
    assert :ok = Poller.report(1, hook, p)
    # only a full-lifecycle hook skips the screen
    assert %{hook_source: "hooks", skipped: false} = Facts.agent(1)
    assert {:error, :not_found} = Poller.report(99, hook, p)

    assert :ok = Poller.release(1, "hooks", "claude", p)
    assert %{hook_source: nil, skipped: false} = Facts.agent(1)
  end
end
