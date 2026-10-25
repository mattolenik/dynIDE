# Ruling 28 measurement (M6 Task 5): does a promoted standby run an edit the primary
# reloaded after the standby booted? Per run: boot the broker headless, wait for
# standby_ready=1, edit a real source (Handoff.Ctl's :ping reply, the one piece of
# editable code whose result the ctl socket returns; the scene is reachable only
# in-VM) to a unique marker, wait until the primary answers ping with it, kill -9 the
# primary, wait for the new primary, then poll ping for 5 s.
# Prints `STALE_STANDBY marker_after_promotion=true|false loaded_after_ms=..` per run
# (loaded_after_ms: kill -> first marker reply from the new primary, `-` if none).
# Usage: cd dynide && elixir bench/handoff/stale_standby.exs [runs=3]
# Exit 1 if any run was stale or dynide/apps is left dirty.
Code.require_file("driver.exs", __DIR__)
alias HandoffDriver, as: D

runs =
  case System.argv() do
    [n] -> String.to_integer(String.trim_leading(n, "runs="))
    _ -> 3
  end

src = Path.join(D.dynide_dir(), "apps/herdr_server/lib/herdr_server/handoff/ctl.ex")
orig = File.read!(src)
needle = "def handle(:ping), do: :pong\n"
String.contains?(orig, needle) || raise "#{src} has no `#{String.trim(needle)}`"

ping = fn dir ->
  c = D.connect(dir)

  try do
    D.request(c, :ping)
  after
    :gen_tcp.close(c)
  end
end

poll = fn dir, want, ms ->
  try do
    D.wait(fn -> ping.(dir) == want end, ms, 20)
  rescue
    _ -> false
  end
end

IO.puts("STALE_STANDBY start #{D.uptime()}")

results =
  for run <- 1..runs do
    marker = :"pong-stale-#{run}-#{System.unique_integer([:positive])}"

    {r, st} =
      D.with_broker("stale", fn b ->
        D.wait(fn -> D.status(b.dir)["standby_ready"] == "1" end, 600_000)
        s0 = D.status(b.dir)

        try do
          File.write!(
            src,
            String.replace(orig, needle, "def handle(:ping), do: #{inspect(marker)}\n")
          )

          poll.(b.dir, marker, 60_000) || raise "primary never loaded the edit"
          # the standby must predate the edit
          D.status(b.dir)["standby_pid"] == s0["standby_pid"] || raise "standby changed"

          t0 = D.now()
          System.cmd("kill", ["-KILL", s0["primary_pid"]])

          D.wait(
            fn ->
              s = D.status(b.dir)
              s["primary_gen"] not in [s0["primary_gen"], "-"] and s["phase"] == "idle"
            end,
            30_000,
            2
          )

          ok = poll.(b.dir, marker, 5_000)
          ms = if ok, do: round(D.now() - t0), else: "-"
          IO.puts("STALE_STANDBY marker_after_promotion=#{ok == true} loaded_after_ms=#{ms}")
          ok == true
        after
          File.write!(src, orig)
          # let the primary reload the restore before the stop (best effort)
          poll.(b.dir, :pong, 10_000)
        end
      end)

    st == 0 || IO.puts("STALE_STANDBY run #{run} broker exit #{inspect(st)}")
    r
  end

{_, dirty} = System.cmd("git", ["diff", "--quiet", "--", "apps"], cd: D.dynide_dir())
dirty == 0 || IO.puts(:stderr, "STALE_STANDBY dynide/apps left dirty")
IO.puts("STALE_STANDBY fresh=#{Enum.count(results, & &1)}/#{runs}")
if dirty != 0 or not Enum.all?(results), do: System.halt(1)
