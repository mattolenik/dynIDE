# Test-on-save gate latency. Run: cd live && HERDR_LIVE_HEADLESS=1 mix run bench/reload/test_gate_bench.exs
# (dev env: the app's own reload pipeline and watcher run). Gate on, adds a marker function to
# view.ex (it has test/view_test.exs), times save -> {:tests, :passed} and save -> {:loaded}, 5
# iterations, restores the file byte for byte, prints a RESULT line with medians.
alias HerdrReload.{Notices, TestGate}

n = 5
file = Path.expand("apps/herdr_server/lib/herdr_server/view.ex")
original = File.read!(file)
true = is_pid(Process.whereis(HerdrReload.Server)) || raise "reload pipeline not running (run in dev)"
Notices.subscribe()
Process.sleep(1000)

wait = fn pattern_fun ->
  receive do
    {:herdr_reload, ev} = m -> if pattern_fun.(ev), do: m, else: :skip
  after
    180_000 -> raise "timeout waiting for notice"
  end
end

await = fn pred ->
  Stream.repeatedly(fn -> wait.(pred) end) |> Enum.find(&(&1 != :skip))
end

measure = fn i ->
  # a comment would not change the beam (no {:loaded}): add a function with a unique body
  body = String.replace_suffix(original, "end\n", "\n  def gate_bench_marker, do: #{i}_#{System.unique_integer([:positive])}\nend\n")
  true = body != original
  File.write!(file, body)
  t0 = System.monotonic_time(:millisecond)
  {:herdr_reload, {:tests, :passed, _}} = await.(&match?({:tests, r, _} when r != :running, &1))
  t1 = System.monotonic_time(:millisecond)
  {:herdr_reload, {:loaded, _, _}} = await.(&match?({:loaded, _, _}, &1))
  t2 = System.monotonic_time(:millisecond)
  IO.puts("iter #{i}: tests passed #{t1 - t0} ms, loaded #{t2 - t0} ms")
  {t1 - t0, t2 - t0}
end

median = fn xs -> xs |> Enum.sort() |> Enum.at(div(length(xs), 2)) end

try do
  TestGate.set_mode(:gate)
  rs = for i <- 1..n, do: measure.(i)
  TestGate.set_mode(:off)
  # restore and wait for its reload so the loaded code is the original again
  File.write!(file, original)
  await.(&match?({:loaded, _, _}, &1))
  IO.puts("RESULT scenario=test_gate n=#{n} passed_median_ms=#{median.(Enum.map(rs, &elem(&1, 0)))} loaded_median_ms=#{median.(Enum.map(rs, &elem(&1, 1)))}")
after
  TestGate.set_mode(:off)
  File.write!(file, original)
end

{_, 0} = System.cmd("git", ["diff", "--quiet", "--", "live/apps"], cd: Path.dirname(File.cwd!()))
IO.puts("clean: git diff --quiet -- live/apps ok")
