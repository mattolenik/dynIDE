defmodule HerdrIntegration.DetectPollCostTest do
  @moduledoc """
  Detection poll cost at 15 panes: fake kernel, the real Engine and bundled
  claude manifest over full 120-column screens. Every pane has new output
  before each tick, so every tick spends its whole scan budget. Asserts the
  median tick under 10 ms and prints p50/p95/max tick µs.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver
  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Detect.Poller
  alias HerdrServer.Kernel.Fake.{Keeper, Pty}
  alias HerdrServer.Mirror
  alias HerdrServer.Pane.Rows

  @panes 15
  @ticks 60
  @size %{cols: 120, rows: 40}

  setup do
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Poller)
    on_exit(fn -> Supervisor.restart_child(HerdrServer.Supervisor, Poller) end)
    Driver.reset()
  end

  test "15 panes: median tick under 10 ms" do
    _client = Driver.start_client({@size.cols, @size.rows + 2})
    for _ <- 2..@panes, do: :ok = Store.run({Actions, :new_tab, []}, @size)
    assert wait(fn -> map_size(Mirror.app().session.panes) == @panes end)
    ids = Mirror.app().session.panes |> Map.keys() |> Enum.sort()
    assert wait(fn -> Enum.all?(ids, &Rows.kernel_id/1) end)

    for id <- ids, do: Driver.output(id, screen())

    p = start_supervised!({Poller, name: :cost_poller, grace_ms: 0, interval_ms: 3_600_000})
    for id <- ids, do: :ok = Poller.force_agent(id, "claude", p)

    us =
      for n <- 1..@ticks do
        for id <- ids, do: Driver.output(id, "\r  tick #{n}")
        for id <- ids, do: sync(id)
        send(p, :tick)
        %{last: %{us: us, scans: scans}} = :sys.get_state(p)
        {us, scans}
      end

    # the first ticks probe every pane and publish its agent
    {us, scans} = us |> Enum.drop(5) |> Enum.unzip()
    # every tick spends the whole budget, and no more
    assert Enum.all?(scans, &(&1 == 4))
    sorted = Enum.sort(us)
    pct = fn q -> Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * q))) end

    IO.puts(
      "DETECT_POLL panes=#{@panes} ticks=#{length(sorted)} p50_us=#{pct.(0.5)} " <>
        "p95_us=#{pct.(0.95)} max_us=#{List.last(sorted)}"
    )

    assert pct.(0.5) < 10_000
  end

  # a claude session: earlier output, then the prompt box at the bottom
  defp screen do
    rule = String.duplicate("─", @size.cols)

    hist =
      for i <- 1..32,
          do: String.pad_trailing("  line #{i}: earlier output from the agent", 118, ".")

    lines = hist ++ ["", rule, "> ", rule, "  ? for shortcuts"]
    Enum.join(lines, "\r\n")
  end

  defp sync(id) do
    {:ok, %{pty: pty}} = Keeper.lookup(Rows.kernel_id(id))
    Pty.activity(pty)
  end

  defp wait(fun, ms \\ 2000) do
    Enum.any?(1..div(ms, 20), fn _ -> fun.() || (Process.sleep(20) && false) end)
  end
end
