# Typing through a graceful kernel-restart (M5 exit criterion): one pane runs
# `cat` in raw mode into a file; a typer pipelines one ctl {:write, id, <<c>>}
# every 5 ms for 8 s over ?a..?z while a second connection runs CTL_RESTART at
# 3 s. Every byte must land in the file once, in order.
# Usage: cd live && elixir bench/handoff/typing.exs        Exit 1 if not equal.
Code.require_file("driver.exs", __DIR__)
alias HandoffDriver, as: D

IO.puts("TYPING start #{D.uptime()}")
n = div(8000, 5)

bench = fn b ->
  file = Path.join(Path.dirname(b.dir), "typed.txt")
  c = D.connect(b.dir)
  id = D.open(c, "/bin/sh", ["-c", "stty raw -echo; exec cat > #{file}"])
  D.wait(fn -> File.exists?(file) end, 10_000)
  # kernel-restart boots a fresh target anyway; waiting for the standby keeps a
  # boot-time compile out of the measurement
  D.wait(fn -> D.status(b.dir)["standby_ready"] == "1" end, 600_000)

  t = D.connect(b.dir)
  # replies come back in request order: the i-th reply answers the i-th write
  receiver = Task.async(fn -> for _ <- 1..n, do: {D.recv_reply(t, 60_000), D.now()} end)
  start = D.now()

  restarter =
    Task.async(fn ->
      Process.sleep(3000)
      t0 = D.now()
      {ok, text} = D.restart(b.dir)
      {ok, text, t0, D.now()}
    end)

  # absolute 5 ms schedule
  sends =
    for i <- 0..(n - 1) do
      wait = round(start + i * 5 - D.now())
      if wait > 0, do: Process.sleep(wait)
      ch = ?a + rem(i, 26)
      ts = D.now()
      :ok = D.send_request(t, {:write, id, <<ch>>})
      {ch, ts}
    end

  {ok, text, r0, r1} = Task.await(restarter, :infinity)
  replies = Task.await(receiver, :infinity)
  errors = Enum.count(replies, fn {r, _} -> r != :ok end)
  expected = for {ch, _} <- sends, into: <<>>, do: <<ch>>
  size = fn -> File.stat!(file).size end

  try do
    D.wait(fn -> size.() >= n end, 30_000, 20)
  rescue
    _ -> :short
  end

  written = size.()
  equal = File.read!(file) == expected
  max_reply = sends |> Enum.zip_with(replies, fn {_, s}, {_, r} -> r - s end) |> Enum.max()
  in_window = Enum.count(replies, fn {_, r} -> r > r0 and r < r1 end)
  s = D.status(b.dir)

  IO.puts(
    "TYPING sent=#{n} written=#{written} equal=#{equal} window_ms=#{s["last_handoff_ms"]} " <>
      "max_reply_ms=#{round(max_reply)} in_window=#{in_window} errors=#{errors} " <>
      "restart_ok=#{ok} restart_wall_ms=#{round(r1 - r0)} kind=#{s["last_handoff_kind"]} " <>
      D.uptime()
  )

  ok || IO.puts("TYPING restart failed: #{text}")
  :gen_tcp.close(t)
  :gen_tcp.close(c)
  equal and ok
end

code =
  try do
    case D.with_broker("typing", bench) do
      {true, 0} -> 0
      {ok, st} -> IO.puts("TYPING fail ok=#{ok} broker_exit=#{inspect(st)}") && 1
    end
  catch
    kind, reason ->
      IO.puts("TYPING fail #{Exception.format(kind, reason, __STACKTRACE__)}")
      1
  end

System.halt(code)
