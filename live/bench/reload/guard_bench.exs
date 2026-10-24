# Guard overhead bench. Run: cd live && mix run bench/reload/guard_bench.exs
alias HerdrReload.{Guard, Server}

defmodule GuardBench do
  def id(x), do: x

  def time(n, f) do
    # Enum.each discards results: a `for` would keep n copies of a 1 MB result
    Enum.each(1..div(n, 10), fn _ -> f.() end)
    t0 = System.monotonic_time(:nanosecond)
    Enum.each(1..n, fn _ -> f.() end)
    Float.round((System.monotonic_time(:nanosecond) - t0) / n / 1000, 3)
  end
end

small = Map.new(1..40, &{&1, String.duplicate("x", 16)})
big = Map.new(1..16_000, &{&1, String.duplicate("x", 50)})
IO.puts("small arg #{:erts_debug.flat_size(small) * 8} B, big arg #{div(:erts_debug.flat_size(big) * 8, 1024)} KiB (heap)")

# the dev app's default Server owns the counters table
true = is_pid(Process.whereis(Server)) || raise "default Reload.Server not running (run in dev)"

rows = [
  {"bare apply/3", fn a -> fn -> apply(GuardBench, :id, [a]) end end, 100_000},
  {"inline scan:false, no counters", fn a -> fn -> Guard.run(GuardBench, :id, [a], server: :no_such_server, scan: false) end end, 100_000},
  {"inline scan:false, counters", fn a -> fn -> Guard.run(GuardBench, :id, [a], server: Server, scan: false) end end, 100_000},
  {"inline scan:true, no counters", fn a -> fn -> Guard.run(GuardBench, :id, [a], server: :no_such_server, scan: true) end end, 10_000},
  {"inline scan:true, counters", fn a -> fn -> Guard.run(GuardBench, :id, [a], server: Server, scan: true) end end, 10_000},
  {"budget 50ms scan:false, no counters", fn a -> fn -> Guard.run(GuardBench, :id, [a], server: :no_such_server, scan: false, budget_ms: 50) end end, 10_000},
  {"budget 50ms scan:false, counters", fn a -> fn -> Guard.run(GuardBench, :id, [a], server: Server, scan: false, budget_ms: 50) end end, 10_000}
]

IO.puts(String.pad_trailing("per call (us)", 40) <> String.pad_leading("small", 12) <> String.pad_leading("~1 MB", 12))

for {label, mk, n} <- rows do
  s = GuardBench.time(n, mk.(small))
  b = GuardBench.time(max(div(n, 10), 100), mk.(big))
  IO.puts(String.pad_trailing(label, 40) <> String.pad_leading("#{s}", 12) <> String.pad_leading("#{b}", 12))
end
