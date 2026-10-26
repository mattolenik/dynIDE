# Detection poll cost against the real kernel (M11 task 6). 15 panes, each running
# `sh -c 'while :; do date; sleep 0.1; done'` (output every 100 ms, so every pane wants a
# scan every tick and the foreground pgid keeps changing), each forced to `claude` with
# `Poller.force_agent/3` (bench hook). A bench-owned Poller (the app's is stopped) runs
# its normal 300 ms ticks; after the 3 s grace, 10 s of ticks are measured.
# Usage (isolated dirs, never the human's session or API socket):
#   cd dynide && t=$(mktemp -d) && HERDR_LIVE_HEADLESS=1 SHELL=/bin/sh HERDR_LIVE_LOG=$t/log \
#     HERDR_LIVE_API=$t/api.sock HERDR_LIVE_RUNTIME_DIR=$t/rt HERDR_LIVE_STATE_DIR=$t/state \
#     mix run bench/detect/poll.exs
# Prints `DETECT_POLL_REAL panes= ticks= scans_per_tick= probes_per_tick= p50_us= p95_us=
#   max_us= load=<uptime>`.
alias DynideScene.Protocol
alias DynideServer.App.{Actions, Store}
alias DynideServer.Detect.Poller
alias DynideServer.{Mirror, Pane.Facts, Pane.Server}

panes = 15
size = %{cols: 120, rows: 40}
load = fn -> System.cmd("uptime", []) |> elem(0) |> String.trim() end
Application.put_env(:dynide_server, :pane_env, [{"PS1", "$ "}, {"HISTFILE", "/dev/null"}])

wait = fn f, ms ->
  Enum.find_value(1..div(ms, 10), fn _ -> f.() || (Process.sleep(10) && nil) end) ||
    raise "timed out"
end

# an in-VM client gives the session its area
client = spawn(fn -> Process.sleep(:infinity) end)

{:ok, _session, _} =
  GenServer.call(
    Protocol.endpoint(),
    {:attach, %{kind: :term, transport: :ref, size: size, cell_px: nil, caps: %{}, client: client}}
  )

wait.(fn -> match?(%{session: %{panes: p}} when map_size(p) > 0, Mirror.app()) end, 5000)
# a request runs while a modal (first-run onboarding) is open, unlike `Store.run/2`
for _ <- 2..panes, do: {:ok, _, _} = Store.request({Actions, :new_tab, []})
wait.(fn -> map_size(Mirror.app().session.panes) == panes end, 5000)
ids = Mirror.app().session.panes |> Map.keys() |> Enum.sort()
wait.(fn -> Enum.all?(ids, &Facts.get/1) end, 5000)
Process.sleep(500)
for id <- ids, do: Server.write(id, "sh -c 'while :; do date; sleep 0.1; done'\r")

:ok = Supervisor.terminate_child(DynideServer.Supervisor, Poller)
{:ok, p} = Poller.start_link(name: :bench_poller, window_ms: 3_600_000)
for id <- ids, do: :ok = Poller.force_agent(id, "claude", p)

Process.sleep(4000)
w0 = :sys.get_state(p).window
IO.puts("DETECT_POLL_REAL start load=#{load.()}")
Process.sleep(10_000)
w1 = :sys.get_state(p).window

n = length(w1.us) - length(w0.us)
sorted = w1.us |> Enum.take(n) |> Enum.sort()
pct = fn q -> Enum.at(sorted, min(n - 1, trunc(n * q))) end

IO.puts(
  "DETECT_POLL_REAL panes=#{panes} ticks=#{n} " <>
    "scans_per_tick=#{Float.round((w1.scans - w0.scans) / n, 2)} " <>
    "probes_per_tick=#{Float.round((w1.probes - w0.probes) / n, 2)} " <>
    "p50_us=#{pct.(0.5)} p95_us=#{pct.(0.95)} max_us=#{List.last(sorted)} " <>
    "agents=#{Enum.count(ids, &match?(%{agent: "claude"}, Facts.agent(&1)))} load=#{load.()}"
)

for id <- ids, do: Server.write(id, "\x03")
