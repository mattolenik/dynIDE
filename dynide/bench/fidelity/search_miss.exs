# Copy-mode worst-case search miss on the real kernel (M9 final review). A real
# `Native.Vt` holds a full 20_000-row scrollback; copy mode searches for a string that is
# not there, so the search reads its whole 20_000-row budget through `screen_rows` (200-row
# windows, DirtyCpu). M18: the search runs in the kernel (`Native.Vt.search/3`, calls of 2000
# rows) in a task off the session; this times the whole path that task and the session run:
# the submitting Enter (`CopyMode.key/3`), `CopyMode.search/1` and `CopyMode.found/4`, both
# directions: `?` from the bottom and `/` after `g` from the top.
# Usage (isolated dirs, never the human's API socket):
#   cd dynide && t=$(mktemp -d) && HERDR_LIVE_HEADLESS=1 HERDR_LIVE_LOG=$t/log HERDR_LIVE_API=$t/api.sock \
#     HERDR_LIVE_RUNTIME_DIR=$t/rt HERDR_LIVE_STATE_DIR=$t/state mix run bench/fidelity/search_miss.exs [--runs N]
# Prints `SEARCH_MISS dir=<..> rows=<total> runs=N min_ms= median_ms= max_ms= load=<uptime>`.
alias HerdrScene.Event
alias HerdrServer.Client.CopyMode
alias HerdrServer.Native.Vt

{opts, _, _} = OptionParser.parse(System.argv(), strict: [runs: :integer])
runs = Keyword.get(opts, :runs, 5)
{cols, rows} = {80, 24}
load = fn -> System.cmd("uptime", []) |> elem(0) |> String.trim() end

{:ok, vt} = Vt.new(cols, rows, 100_000_000)

1..(20_000 + rows)
|> Stream.chunk_every(2000)
|> Enum.each(fn c -> Vt.feed(vt, Enum.map_join(c, &"line #{&1} lorem ipsum dolor\r\n")) end)

sb = Vt.scrollbar(vt)
if sb.total < 20_000 + rows, do: raise("scrollback holds only #{sb.total} rows")

ctx = fn ->
  %{
    scroll: Vt.scrollbar(vt),
    h: rows,
    w: cols,
    read: {Vt, :screen_rows, [vt]},
    search: {Vt, :search, [vt]}
  }
end

press = fn t, keys ->
  Enum.reduce(keys, t, fn k, t ->
    {t, _} = CopyMode.key(t, Event.key(k), ctx.())
    t
  end)
end

time_miss = fn prefix ->
  t = CopyMode.enter(1, %{cursor: nil, scroll: Vt.scrollbar(vt), h: rows, w: cols})
  t = press.(t, prefix ++ String.graphemes("zqxjv"))
  t0 = System.monotonic_time(:microsecond)
  {t, [{:search, id, req}]} = CopyMode.key(t, Event.key(:enter), ctx.())
  {_t, actions} = CopyMode.found(t, id, CopyMode.search(req), ctx.())
  us = System.monotonic_time(:microsecond) - t0
  true = Enum.any?(actions, &match?({:notice, %{text: "no match" <> _}}, &1))
  us / 1000
end

IO.puts("SEARCH_MISS start load=#{load.()}")

for {dir, prefix} <- [backward_from_bottom: ["?"], forward_from_top: ["g", "/"]] do
  ms = for _ <- 1..runs, do: time_miss.(prefix)
  s = Enum.sort(ms)
  f = &:erlang.float_to_binary(&1, decimals: 1)

  IO.puts(
    "SEARCH_MISS dir=#{dir} rows=#{sb.total} runs=#{runs} min_ms=#{f.(hd(s))} " <>
      "median_ms=#{f.(Enum.at(s, div(runs, 2)))} max_ms=#{f.(List.last(s))} load=#{load.()}"
  )
end
