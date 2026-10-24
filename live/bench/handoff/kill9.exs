# kill -9 bench (M5 exit criterion): 15 panes (5 htop, 5 `yes | head` loops,
# 5 shells that ran `seq 1 3000`) survive repeated kill -9 of the primary VM.
# Each run waits for standby_ready=1 plus 1.5 s (a snapshot), kills, and times
# kill -> new primary_gen with phase=idle. A final cold run kills twice back to
# back, the second time before a new standby is ready (Review Focus 5).
# Usage: cd live && elixir bench/handoff/kill9.exs [runs=12]
# Exit 1 if any child died or the warm p95 >= 1000 ms.
Code.require_file("driver.exs", __DIR__)
alias HandoffDriver, as: D

runs =
  case System.argv() do
    [n] -> String.to_integer(String.trim_leading(n, "runs="))
    _ -> 12
  end

htop =
  System.find_executable("htop") ||
    Enum.find(["/opt/homebrew/bin/htop", "/usr/local/bin/htop"], &File.exists?/1)

htop || IO.puts("KILL9 note: htop not found, skipping the 5 htop panes")
IO.puts("KILL9 start #{D.uptime()}")

bench = fn b ->
  c = D.connect(b.dir)
  sc = D.connect(b.dir)
  htop_ids = if htop, do: for(_ <- 1..5, do: D.open(c, htop, [])), else: []
  loop = "while :; do yes | head -n 2000; sleep 0.1; done"
  yes_ids = for _ <- 1..5, do: D.open(c, "/bin/sh", ["-c", loop])
  seq_ids = for _ <- 1..5, do: D.open(c, "/bin/sh", [])

  for id <- seq_ids do
    :ok = D.request(c, {:write, id, "seq 1 3000\n"})
    D.wait(fn -> D.has_line?(c, id, "3000") end, 30_000, 50)
  end

  ids = htop_ids ++ yes_ids ++ seq_ids
  pids = Map.take(D.panes(c), ids)
  map_size(pids) == length(ids) || raise "panes missing: #{inspect(pids)}"

  check = fn run ->
    now = D.panes(c)
    alive = Enum.count(pids, fn {id, p} -> now[id] == p and D.alive?(p) end)

    answered =
      seq_ids
      |> Enum.with_index(1)
      |> Enum.count(fn {id, n} -> D.answers?(c, id, "m5-#{run}-#{n}") end)

    scrollback = Enum.count(seq_ids, &(D.text(c, &1) =~ "2999"))

    htop_ok =
      Enum.count(htop_ids, fn id ->
        try do
          D.wait(fn -> (t = D.text(c, id)) =~ "Load average" or t =~ "Tasks" end, 2_000, 50)
        rescue
          _ -> false
        end
      end)

    {alive, answered, scrollback, htop_ok}
  end

  ready = fn -> D.wait(fn -> D.status(sc)["standby_ready"] == "1" end, 600_000) end

  ready.()
  Process.sleep(1500)
  s = D.status(sc)
  rss = fn pid -> String.trim(elem(System.cmd("ps", ["-o", "rss=", "-p", pid]), 0)) end

  IO.puts(
    "KILL9 rss primary_kb=#{rss.(s["primary_pid"])} standby_kb=#{rss.(s["standby_pid"])} panes=#{length(ids)} #{D.uptime()}"
  )

  kill = fn ->
    s0 = D.status(sc)
    t0 = D.now()
    System.cmd("kill", ["-KILL", s0["primary_pid"]])

    s1 =
      D.wait(
        fn ->
          s = D.status(sc)
          s["primary_gen"] not in [s0["primary_gen"], "-"] and s["phase"] == "idle" and s
        end,
        120_000,
        2
      )

    {round(D.now() - t0), s0, s1}
  end

  line = fn run, wall, s0, s1, {alive, answered, scrollback, htop_ok}, extra ->
    IO.puts(
      "KILL9 run=#{run} wall_ms=#{wall} broker_ms=#{s1["last_handoff_ms"]} " <>
        "alive=#{alive}/#{length(ids)} answered=#{answered}/#{length(seq_ids)} " <>
        "scrollback=#{scrollback}/#{length(seq_ids)} htop=#{htop_ok}/#{length(htop_ids)} " <>
        "standby_ready=#{s0["standby_ready"]} kind=#{s1["last_handoff_kind"]}#{extra}"
    )

    alive
  end

  warm =
    for run <- 1..runs do
      ready.()
      Process.sleep(1500)
      {wall, s0, s1} = kill.()
      alive = line.(run, wall, s0, s1, check.(run), "")
      {wall, alive}
    end

  # Cold: a warm kill, then at once a second kill while the new standby boots.
  ready.()
  Process.sleep(1500)
  {prep_wall, _, _} = kill.()
  {wall, s0, s1} = kill.()
  s0["standby_ready"] == "0" || IO.puts("KILL9 note: the cold run found a ready standby")
  cold_alive = line.("cold", wall, s0, s1, check.(runs + 1), " prep_wall_ms=#{prep_wall}")

  walls = warm |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  died = Enum.any?(warm, fn {_, a} -> a != length(ids) end) or cold_alive != length(ids)
  p95 = D.percentile(walls, 95)

  IO.puts(
    "KILL9 p50=#{D.percentile(walls, 50)} p95=#{p95} max=#{List.last(walls)} runs=#{runs} " <>
      "cold_ms=#{wall} #{D.uptime()}"
  )

  :gen_tcp.close(c)
  :gen_tcp.close(sc)
  not died and p95 < 1000
end

code =
  try do
    case D.with_broker("kill9", bench) do
      {true, 0} -> 0
      {ok, st} -> IO.puts("KILL9 fail ok=#{ok} broker_exit=#{inspect(st)}") && 1
    end
  catch
    kind, reason ->
      IO.puts("KILL9 fail #{Exception.format(kind, reason, __STACKTRACE__)}")
      1
  end

System.halt(code)
