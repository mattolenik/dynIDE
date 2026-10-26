# A scrolled-back pane streaming output, two in-VM clients attached (M9 final review).
# Real kernel: pane 1 runs `yes`, is scrolled back 10 rows, and for 5 s the script counts
# each client's `{:scene, _}` pushes and the sessions' `Store.snapshot` calls (a facts
# repaint). Pane.Server and Client.Session throttle facts repaints to one per 16 ms, so
# each client should stay near 60 pushes/s, not one per 4 ms damage window.
# Usage (isolated dirs, never the human's session or API socket):
#   cd dynide && t=$(mktemp -d) && HERDR_LIVE_HEADLESS=1 SHELL=/bin/sh HERDR_LIVE_LOG=$t/log \
#     HERDR_LIVE_API=$t/api.sock HERDR_LIVE_RUNTIME_DIR=$t/rt HERDR_LIVE_STATE_DIR=$t/state \
#     mix run bench/fidelity/scrolled_stream.exs
# Prints `SCROLLED_STREAM secs=5 client_a_pushes_per_s= client_b_pushes_per_s=
#   snapshots_per_s= scrolled_at_end= load=<uptime>`.
alias DynideScene.Protocol
alias DynideServer.App.Store
alias DynideServer.Kernel
alias DynideServer.Pane.{Facts, Rows, Server}

secs = 5
load = fn -> System.cmd("uptime", []) |> elem(0) |> String.trim() end
Application.put_env(:dynide_server, :pane_env, [{"PS1", "$ "}, {"HISTFILE", "/dev/null"}])

# an in-VM client: counts scene pushes, reports and resets on {:count, from}
client = fn ->
  loop = fn loop, n ->
    receive do
      {:scene, _} -> loop.(loop, n + 1)
      {:count, from} -> send(from, {:count, self(), n}) && loop.(loop, 0)
      _ -> loop.(loop, n)
    end
  end

  loop.(loop, 0)
end

attach = fn ->
  pid = spawn(client)

  info = %{
    kind: :term,
    transport: :ref,
    size: %{cols: 100, rows: 30},
    cell_px: nil,
    caps: %{},
    client: pid
  }

  {:ok, session, _} = GenServer.call(Protocol.endpoint(), {:attach, info})
  {pid, session}
end

count = fn pid ->
  send(pid, {:count, self()})

  receive do
    {:count, ^pid, n} -> n
  after
    1000 -> raise "client #{inspect(pid)} did not answer"
  end
end

wait = fn f, ms ->
  Enum.find_value(1..div(ms, 10), fn _ -> f.() || (Process.sleep(10) && nil) end) ||
    raise "timed out"
end

{a, sa} = attach.()
{b, sb} = attach.()

focused = fn ->
  case Store.snapshot() do
    %{focus: %{pane: p}} -> p
    _ -> nil
  end
end

id = wait.(focused, 5000)
wait.(fn -> Facts.get(id) end, 5000)
Process.sleep(500)
Server.write(id, "yes\r")
# facts hold the scroll only while scrolled: read the vt until `yes` has built history
{:ok, %{vt: vt}} = Kernel.keeper().lookup(Rows.kernel_id(id))
wait.(fn -> Kernel.vt().scrollbar(vt).total > 1000 end, 10_000)
Server.scroll(id, {:delta, -10})
wait.(fn -> Facts.get(id).scrolled end, 5000)

store = Process.whereis(Store)
:erlang.trace(store, true, [:receive])
for p <- [a, b], do: count.(p)
IO.puts("SCROLLED_STREAM start load=#{load.()}")
Process.sleep(secs * 1000)
[na, nb] = Enum.map([a, b], count)
:erlang.trace(store, false, [:receive])

snaps =
  Stream.repeatedly(fn ->
    receive do
      {:trace, _, :receive, {:"$gen_call", {s, _}, :snapshot}} when s in [sa, sb] -> 1
      {:trace, _, :receive, _} -> 0
    after
      0 -> nil
    end
  end)
  |> Enum.take_while(&(&1 != nil))
  |> Enum.sum()

%{scrolled: scrolled, scroll: sb_end} = Facts.get(id)
Server.write(id, "\x03")

IO.puts(
  "SCROLLED_STREAM secs=#{secs} client_a_pushes_per_s=#{Float.round(na / secs, 1)} " <>
    "client_b_pushes_per_s=#{Float.round(nb / secs, 1)} snapshots=#{snaps} " <>
    "snapshots_per_s=#{Float.round(snaps / secs, 1)} scrolled_at_end=#{scrolled} total_at_end=#{sb_end.total} load=#{load.()}"
)
