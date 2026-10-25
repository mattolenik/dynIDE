# Handoff smoke (run by `just live-check`): 3 shells survive one kill -9 of the
# primary VM and one graceful kernel-restart with the same pids, each answers
# afterwards, a kitty image placed through the pty before the graceful restart keeps
# its placements, and the broker stops with exit 0.
# Usage: cd live && elixir bench/handoff/smoke.exs
Code.require_file("driver.exs", __DIR__)
alias HandoffDriver, as: D

run = fn b ->
  c = D.connect(b.dir)
  ids = for _ <- 1..3, do: D.open(c, "/bin/sh", [])
  pids = Map.take(D.panes(c), ids)
  counter = :counters.new(1, [])

  check = fn label ->
    now = Map.take(D.panes(c), ids)
    now == pids || raise "#{label}: pane pids #{inspect(pids)} became #{inspect(now)}"
    Enum.all?(Map.values(pids), &D.alive?/1) || raise "#{label}: a child died"

    for id <- ids do
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      D.answers?(c, id, "smoke-#{n}", 10_000) || raise "#{label}: pane #{id} did not answer"
    end
  end

  check.("before")
  D.wait(fn -> D.status(b.dir)["standby_ready"] == "1" end, 600_000)
  Process.sleep(1500)
  s0 = D.status(b.dir)
  System.cmd("kill", ["-KILL", s0["primary_pid"]])

  s1 =
    D.wait(
      fn ->
        s = D.status(b.dir)
        s["primary_gen"] not in [s0["primary_gen"], "-"] and s["phase"] == "idle" and s
      end,
      120_000,
      2
    )

  s1["last_handoff_kind"] == "crash" ||
    raise "crash: last_handoff_kind=#{s1["last_handoff_kind"]}"

  check.("crash")

  # 2x2 RGB through the child's output; q=2 so no reply reaches the shell
  img = ~S"printf '\033_Ga=T,q=2,f=24,s=2,v=2,i=7,c=4,r=2;AQIDBAUGBwgJCgsM\033\\'; echo"
  :ok = D.request(c, {:write, hd(ids), img <> "\n"})
  gfx = fn -> elem(D.request(c, {:graphics, hd(ids)}), 1) end
  D.wait(fn -> gfx.() != [] end, 10_000, 20)
  placed = gfx.()

  {true, _} = D.restart(b.dir)
  gfx.() == placed || raise "graceful: placements #{inspect(placed)} became #{inspect(gfx.())}"
  s2 = D.status(b.dir)
  s2["last_handoff_kind"] == "graceful" || raise "graceful: #{inspect(s2)}"
  check.("graceful")
  :gen_tcp.close(c)
  {s1["last_handoff_ms"], s2["last_handoff_ms"]}
end

code =
  try do
    case D.with_broker("smoke", run) do
      {{crash, graceful}, 0} ->
        IO.puts("HANDOFF_SMOKE ok crash_ms=#{crash} graceful_ms=#{graceful}")
        0

      {_, st} ->
        IO.puts("HANDOFF_SMOKE fail broker exit #{inspect(st)}")
        1
    end
  catch
    kind, reason ->
      IO.puts("HANDOFF_SMOKE fail #{Exception.format(kind, reason, __STACKTRACE__)}")
      1
  end

System.halt(code)
