# Scrollback persistence cost (M8 task 7, ADR 0002). For each workload (`seq` lines and
# `ls -la --color`-like SGR lines, 80 cols) and history size (1000, 10 000 rows, and the
# full history ghostty keeps under the 10 MB max_scrollback, at most 100 000 lines fed)
# it prints one line per option:
#   SCROLLBACK option=<none|tail|snapshot> work=<w> rows=<N> bytes=<on disk> raw=<bytes>
#     encode_us=<capture> write_us=<Disk write> restore_us=<rebuild>
# tail = Vt.tail_ansi/2 (clamped to 10 000 rows by the kernel), restore = Vt.new + feed;
# snapshot = Vt.encode_snapshot/1, restore = Vt.restore/2. Both are written through
# Disk.write_scrollback/4 (compressed ETF, synced) into a temp dir, removed at the end.
# Then write amplification for 15 panes changing every minute at the 60 s cadence.
# Usage: cd dynide && DYNIDE_HEADLESS=1 mix run bench/persist/scrollback_cost.exs
# (no broker, so persistence is off). Timings on a loaded host are upper bounds.
alias DynideServer.Native.Vt
alias DynideServer.Persist.Disk

max_sb = 10_000_000
cols = 80
rows = 24
panes = 15
cadence_s = 60

{up, 0} = System.cmd("uptime", [])
IO.puts("SCROLLBACK start load=#{String.trim(up)}")

tmp = Path.join(System.tmp_dir!(), "dynide-sb-bench-#{System.unique_integer([:positive])}")
cfg = Map.merge(Disk.config(), %{dir: tmp, name: "bench"})

seq_line = fn i -> "#{i}\r\n" end

names = ~w(apps bench config deps docs lib mix.exs mix.lock native priv scripts test)

sgr_line = fn i ->
  name = Enum.at(names, rem(i, length(names)))
  {mode, color} = if rem(i, 3) == 0, do: {"drwxr-xr-x", "01;34"}, else: {"-rw-r--r--", "00"}
  size = String.pad_leading(Integer.to_string(rem(i * 7919, 999_999)), 7)

  pre =
    "#{mode}  1 matt  staff  #{size} Oct 24 12:#{String.pad_leading("#{rem(i, 60)}", 2, "0")} "

  # pad the visible text to 79 columns so each line fills one row without wrapping
  vis = "#{name}-#{i}"
  pad = String.duplicate(" ", max(0, 79 - String.length(pre) - String.length(vis)))
  "#{pre}\e[#{color}m#{vis}\e[0m#{pad}\r\n"
end

feed_lines = fn vt, line, from, to ->
  from..to
  |> Stream.chunk_every(2000)
  |> Enum.each(fn chunk -> Vt.feed(vt, IO.iodata_to_binary(Enum.map(chunk, line))) end)
end

time = fn f ->
  t0 = System.monotonic_time(:microsecond)
  r = f.()
  {r, System.monotonic_time(:microsecond) - t0}
end

disk = fn id, bin ->
  {:ok, us} = time.(fn -> Disk.write_scrollback(cfg, id, bin, cols) end)
  %{size: size} = File.stat!(Path.join(Disk.scrollback_dir(cfg), "#{id}.etf"))
  {size, us}
end

# history to feed per target: full = up to 100 000 lines, stop when ghostty stops growing
build = fn line, target ->
  {:ok, vt} = Vt.new(cols, rows, max_sb)

  case target do
    :full ->
      Enum.reduce_while(Stream.iterate(1, &(&1 + 10_000)), 0, fn from, prev ->
        to = min(from + 9_999, 100_000)
        feed_lines.(vt, line, from, to)
        total = Vt.scrollbar(vt).total

        if to >= 100_000 or total <= prev, do: {:halt, total}, else: {:cont, total}
      end)

    n ->
      # n history rows plus a full screen, so the tail of n rows is all content
      feed_lines.(vt, line, 1, n + rows - 1)
  end

  vt
end

results =
  for {work, line} <- [seq: seq_line, sgr: sgr_line], target <- [1000, 10_000, :full] do
    vt = build.(line, target)
    held = Vt.scrollbar(vt).total
    n = if target == :full, do: held, else: target
    label = if target == :full, do: "full(#{held})", else: "#{n}"

    IO.puts(
      "SCROLLBACK option=none work=#{work} rows=#{label} bytes=0 raw=0 encode_us=0 write_us=0 restore_us=0"
    )

    {tail, t_enc} = time.(fn -> Vt.tail_ansi(vt, n) end)
    {t_size, t_wr} = disk.(1, tail)

    {_, t_res} =
      time.(fn ->
        {:ok, v2} = Vt.new(cols, rows, max_sb)
        Vt.feed(v2, tail)
      end)

    IO.puts(
      "SCROLLBACK option=tail work=#{work} rows=#{label} bytes=#{t_size} raw=#{byte_size(tail)} " <>
        "encode_us=#{t_enc} write_us=#{t_wr} restore_us=#{t_res}"
    )

    {snap, s_enc} = time.(fn -> Vt.encode_snapshot(vt) end)
    {s_size, s_wr} = disk.(2, snap)
    {{:ok, _}, s_res} = time.(fn -> Vt.restore(snap, max_sb) end)

    IO.puts(
      "SCROLLBACK option=snapshot work=#{work} rows=#{label} bytes=#{s_size} raw=#{byte_size(snap)} " <>
        "encode_us=#{s_enc} write_us=#{s_wr} restore_us=#{s_res}"
    )

    {{work, target}, %{tail: t_size, snapshot: s_size}}
  end
  |> Map.new()

writes_per_hour = div(3600, cadence_s)

for {work, _} <- [seq: nil, sgr: nil], target <- [1000, 10_000] do
  %{tail: b} = results[{work, target}]
  per_hour = b * panes * writes_per_hour

  IO.puts(
    "SCROLLBACK amplification option=tail work=#{work} rows=#{target} panes=#{panes} " <>
      "cadence_s=#{cadence_s} bytes_per_write=#{b} bytes_per_hour=#{per_hour} " <>
      "mb_per_day=#{Float.round(per_hour * 24 / 1_000_000, 1)}"
  )
end

for {work, _} <- [seq: nil, sgr: nil] do
  %{snapshot: b} = results[{work, :full}]
  per_hour = b * panes * writes_per_hour

  IO.puts(
    "SCROLLBACK amplification option=snapshot work=#{work} rows=full panes=#{panes} " <>
      "cadence_s=#{cadence_s} bytes_per_write=#{b} bytes_per_hour=#{per_hour} " <>
      "mb_per_day=#{Float.round(per_hour * 24 / 1_000_000, 1)}"
  )
end

File.rm_rf!(tmp)
{up, 0} = System.cmd("uptime", [])
IO.puts("SCROLLBACK end load=#{String.trim(up)}")
