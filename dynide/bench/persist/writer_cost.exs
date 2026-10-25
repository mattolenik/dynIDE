# Persist writer tick and restore cost at 15 panes, 200x50, real NIF kernel (M8).
# Part 1: one writer poll tick = Facts.collect + Schema.capture + Disk.write (median/max
#   of 50), and the unchanged tick (collect + capture + compare, no write).
# Part 2: Keeper.open/1 for 15 panes with a 1000-row SGR replay each (the restore path).
# Usage: cd dynide && HERDR_LIVE_HEADLESS=1 mix run bench/persist/writer_cost.exs
# (dev env, no broker, so the app's own Writer is off). Timings on a loaded host are upper bounds.
alias HerdrServer.App.{Actions, Store}
alias HerdrServer.Native.Keeper
alias HerdrServer.Persist.{Disk, Facts, Schema}

iters = 50
target = 15
size = %{cols: 200, rows: 51}

{up, 0} = System.cmd("uptime", [])
IO.puts("WRITER start load=#{String.trim(up)}")

tmp = Path.join(System.tmp_dir!(), "herdr-writer-bench-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)
cfg = Map.merge(Disk.config(), %{dir: tmp, enabled: true})

time = fn f ->
  t0 = System.monotonic_time(:microsecond)
  r = f.()
  {r, System.monotonic_time(:microsecond) - t0}
end

stats = fn xs ->
  s = Enum.sort(xs)
  {Enum.at(s, div(length(s), 2)), List.last(s)}
end

try do
  Store.event({:resize, size}, size)

  Enum.reduce_while(1..200, :horizontal, fn _, dir ->
    if map_size(Store.snapshot().session.panes) >= target do
      {:halt, dir}
    else
      before = map_size(Store.snapshot().session.panes)
      Store.run({Actions, :split, [dir]}, size)
      # a refused split (focused pane too small): move focus on and try again
      if map_size(Store.snapshot().session.panes) == before,
        do: Store.run({Actions, :cycle, [:next]}, size)

      {:cont, if(dir == :horizontal, do: :vertical, else: :horizontal)}
    end
  end)

  Process.sleep(500)
  app = Store.snapshot()
  n = map_size(app.session.panes)
  IO.puts("WRITER panes=#{n}")

  tick = fn ->
    facts = Facts.collect(app, %{})
    snap = Schema.capture(app, facts)
    :ok = Disk.write(cfg, snap)
    snap
  end

  tick.()
  full = for _ <- 1..iters, do: elem(time.(tick), 1)

  prev_facts = Facts.collect(app, %{})
  prev_snap = Schema.capture(app, prev_facts)

  unchanged =
    for _ <- 1..iters do
      {_, us} =
        time.(fn ->
          facts = Facts.collect(app, prev_facts)
          Schema.capture(app, facts) == prev_snap
        end)

      us
    end

  bytes =
    Path.wildcard(Path.join(tmp, "**/*")) |> Enum.filter(&File.regular?/1) |> Enum.map(&File.stat!(&1).size)

  {fm, fx} = stats.(full)
  {um, ux} = stats.(unchanged)
  IO.puts("WRITER tick_write median_us=#{fm} max_us=#{fx} n=#{iters}")
  IO.puts("WRITER tick_unchanged median_us=#{um} max_us=#{ux} n=#{iters}")
  IO.puts("WRITER snapshot_bytes=#{inspect(bytes)}")

  # --- restore ---
  names = ~w(apps bench config deps docs lib mix.exs mix.lock native priv scripts test)

  line = fn i ->
    name = Enum.at(names, rem(i, length(names)))
    color = if rem(i, 3) == 0, do: "01;34", else: "00"
    pre = "-rw-r--r--  1 matt  staff  #{String.pad_leading("#{rem(i * 7919, 999_999)}", 7)} Oct 24 12:00 "
    vis = "#{name}-#{i}"
    pad = String.duplicate(" ", max(0, 79 - String.length(pre) - String.length(vis)))
    "#{pre}\e[#{color}m#{vis}\e[0m#{pad}\r\n"
  end

  replay = IO.iodata_to_binary(Enum.map(1..1000, line))

  spec = %{
    cmd: System.get_env("SHELL", "/bin/sh"),
    args: [],
    env: [],
    cwd: System.tmp_dir!(),
    cols: 80,
    rows: 24,
    max_scrollback: 10_000_000,
    replay: replay,
    subscriber: nil
  }

  {ids, total} =
    time.(fn ->
      for _ <- 1..target do
        {:ok, id} = Keeper.open(spec)
        id
      end
    end)

  IO.puts(
    "WRITER restore replay_bytes=#{byte_size(replay)} total_ms=#{Float.round(total / 1000, 1)} per_pane_ms=#{Float.round(total / 1000 / target, 2)}"
  )

  Enum.each(ids, &Keeper.close/1)
after
  Store.reset()
  File.rm_rf!(tmp)
  {up, 0} = System.cmd("uptime", [])
  IO.puts("WRITER end load=#{String.trim(up)}")
end
