# Remote attach bench (M16): a raw wire client against a headless instance in a tmp dir.
# Usage (from live/, plain elixir, no mix):
#   elixir bench/remote/bench.exs unix|relay|ssh=<target> [keys=200] [flood=20] [mb=100]
#                                 [panes=15] [only=typing|flood]
# unix: the client socket directly (reads client.token). relay: bench/remote/fake_ssh.sh as a
# Port, the argv `attach <host>` uses (R13); the relay authenticates. ssh=<target>: the same
# argv with a real ssh ($HERDR_LIVE_SSH else ssh, $HERDR_LIVE_REMOTE_BIN else herdr-live).
# Framing is duplicated here (len::32-big + ETF, decoded without [:safe]: we trust our own
# server) instead of loading the compiled apps. Packed rows: 32-byte cells, glyph first.
# frame_ms is a server config value (config/config.exs, default 8) with no per-run override;
# the bench prints what the config says. Every metric is one `REMOTE ` line.
# HERDR_BENCH_SERVER_ROOT=<dir> with ssh=<target>: no local broker; the server is already
# running on <target> with its API socket at <dir>/ctl.sock, and the CLI calls and the flood
# file go over the same ssh (bench/remote/linux_ssh.sh). The relay finds the instance through
# HERDR_LIVE_API, which the ssh command must forward (SendEnv, AcceptEnv on the server).
Code.require_file("../handoff/driver.exs", __DIR__)
alias HandoffDriver, as: D

defmodule RemoteBench do
  @live Path.expand("../..", __DIR__)

  def uptime, do: elem(System.cmd("uptime", []), 0) |> String.trim()

  def load do
    case Regex.run(~r/load averages?:\s*(.*)$/, uptime()) do
      [_, l] -> l |> String.split([" ", ","], trim: true) |> Enum.join("/")
      _ -> "?"
    end
  end

  def server_root, do: System.get_env("HERDR_BENCH_SERVER_ROOT")

  # a shell command on the server host: over ssh when the server is remote, else locally
  def on_server(cmd) do
    case {server_root(), System.get_env("BENCH_TRANSPORT")} do
      {root, "ssh=" <> target} when is_binary(root) ->
        [exe | pre] = String.split(System.get_env("HERDR_LIVE_SSH", "ssh"))

        System.cmd(System.find_executable(exe) || exe, pre ++ ["-T", target, cmd],
          stderr_to_stdout: true
        )

      _ ->
        System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
    end
  end

  def sq(a), do: "'" <> String.replace(a, "'", "'\\''") <> "'"

  def cli(%{remote: true} = b, args) do
    bin = System.get_env("HERDR_LIVE_REMOTE_BIN", "herdr-live")
    api = Path.join(b.root, "ctl.sock")

    {out, st} =
      on_server(Enum.map_join(["env", "HERDR_LIVE_API=" <> api, bin | args], " ", &sq/1))

    st == 0 || raise "herdr-live #{Enum.join(args, " ")} failed (#{st}): #{out}"
    out
  end

  def cli(b, args) do
    {out, st} =
      System.cmd(Path.join(@live, "bin/herdr-live"), args,
        env: [
          {"HERDR_LIVE_API", Path.join(b.root, "ctl.sock")},
          {"HERDR_LIVE_STATE_DIR", Path.join(b.root, "state")},
          {"PATH", D.path()}
        ],
        stderr_to_stdout: true
      )

    st == 0 || raise "herdr-live #{Enum.join(args, " ")} failed (#{st}): #{out}"
    out
  end

  # first "pane_id":"..." / digits after it in a CLI JSON reply
  def pane_id(out) do
    [_, id] = Regex.run(~r/"pane_id"\s*:\s*"?p?(\d+)/, out)
    String.to_integer(id)
  end

  # ---- transport ----

  def connect(b, "unix") do
    sock = Path.join(b.root, "client.sock")

    D.wait(
      fn -> File.exists?(sock) and File.exists?(Path.join(b.root, "client.token")) end,
      60_000
    )

    token = b.root |> Path.join("client.token") |> File.read!() |> String.trim()
    {:ok, s} = :gen_tcp.connect({:local, sock}, 0, [:binary, packet: :raw, active: true])
    :ok = :gen_tcp.send(s, frame({:auth, token}))
    {:tcp, s}
  end

  def connect(b, "relay") do
    D.wait(fn -> File.exists?(Path.join(b.root, "client.token")) end, 60_000)
    open_ssh(b, Path.join(__DIR__, "fake_ssh.sh"), "fakehost", Path.join(@live, "bin/herdr-live"))
  end

  def connect(b, "ssh=" <> target) do
    b[:remote] || D.wait(fn -> File.exists?(Path.join(b.root, "client.token")) end, 60_000)
    exe = System.get_env("HERDR_LIVE_SSH", "ssh")
    open_ssh(b, exe, target, System.get_env("HERDR_LIVE_REMOTE_BIN", "herdr-live"))
  end

  # same argv as HerdrTerm.Remote.Args.ssh_command/2
  defp open_ssh(b, ssh, host, bin) do
    [exe | pre] = String.split(ssh)
    exe = System.find_executable(exe) || exe
    opts = ~w(-T -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

    p =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        args: pre ++ opts ++ [host, bin, "attach-relay"],
        env: [
          {~c"HERDR_LIVE_API", String.to_charlist(Path.join(b.root, "ctl.sock"))},
          {~c"HERDR_LIVE_STATE_DIR", String.to_charlist(Path.join(b.root, "state"))},
          {~c"PATH", String.to_charlist(D.path())}
        ]
      ])

    {:port, p}
  end

  def frame(term) do
    etf = :erlang.term_to_binary(term)
    <<byte_size(etf)::32-big, etf::binary>>
  end

  def send_frame({:tcp, s}, term), do: :ok = :gen_tcp.send(s, frame(term))
  def send_frame({:port, p}, term), do: Port.command(p, frame(term))

  def close({:tcp, s}), do: :gen_tcp.close(s)
  def close({:port, p}), do: if(Port.info(p), do: Port.close(p))

  # ---- client state: %{conn, buf, rows: %{pane => %{n => row}}, bytes, frames, seq, attached} ----

  def new(conn),
    do: %{conn: conn, buf: "", rows: %{}, bytes: 0, frames: 0, seq: 0, attached: false}

  # waits up to `ms` for one chunk; {:ok, st, t_recv_us} | {:timeout, st}
  def pump(%{conn: conn} = st, ms) do
    {tcp, port} =
      case conn do
        {:tcp, s} -> {s, nil}
        {:port, p} -> {nil, p}
      end

    receive do
      {:tcp, ^tcp, d} -> {:ok, ingest(st, d), now()}
      {^port, {:data, d}} -> {:ok, ingest(st, d), now()}
      {:tcp_closed, ^tcp} -> raise "socket closed"
      {^port, {:exit_status, s}} -> raise "relay exited #{s}"
    after
      ms -> {:timeout, st}
    end
  end

  def now, do: System.monotonic_time(:microsecond)

  defp ingest(st, d) do
    parse(%{st | buf: st.buf <> d, bytes: st.bytes + byte_size(d)})
  end

  defp parse(%{buf: <<len::32-big, etf::binary-size(len), rest::binary>>} = st) do
    st = apply_msg(%{st | buf: rest, frames: st.frames + 1}, :erlang.binary_to_term(etf))
    parse(st)
  end

  defp parse(st), do: st

  defp apply_msg(st, {:attached, _}), do: %{st | attached: true}
  defp apply_msg(_st, {:refused, why}), do: raise("refused: #{why}")

  defp apply_msg(st, {:scene, %{panes: panes}}) do
    Enum.reduce(panes, st, fn
      %{id: id, rows: {:inline, rows}}, st -> put_rows(st, id, rows)
      _, st -> st
    end)
  end

  defp apply_msg(st, {:rows, id, _gen, rows}), do: put_rows(st, id, rows)
  defp apply_msg(st, _), do: st

  defp put_rows(st, id, rows) do
    cur = Map.get(st.rows, id, %{})

    %{
      st
      | rows: Map.put(st.rows, id, Enum.reduce(rows, cur, fn {n, r}, m -> Map.put(m, n, r) end))
    }
  end

  def pane_ids(st), do: Map.keys(st.rows)

  # cells of `letter` in the pane's cached rows
  def count(st, id, letter) do
    for {_, row} <- Map.get(st.rows, id, %{}), reduce: 0 do
      acc ->
        cells = binary_part(row, 0, byte_size(row) - 4 - trailer_len(row))
        acc + cnt(cells, letter, 0)
    end
  end

  defp trailer_len(row) do
    <<t::32-little>> = binary_part(row, byte_size(row), -4)
    t
  end

  defp cnt(<<l, 0, _::binary-size(30), rest::binary>>, l, n), do: cnt(rest, l, n + 1)
  defp cnt(<<_::binary-size(32), rest::binary>>, l, n), do: cnt(rest, l, n)
  defp cnt(_, _, n), do: n

  # any non-blank glyph in the pane
  def drawn?(st, id) do
    Enum.any?(Map.get(st.rows, id, %{}), fn {_, row} ->
      cells = binary_part(row, 0, byte_size(row) - 4 - trailer_len(row))
      for(<<g, _::binary-size(31) <- cells>>, g not in [0, ?\s], do: g) != []
    end)
  end

  def attach(conn, cols, rows) do
    send_frame(
      conn,
      {:attach,
       %{
         version: 1,
         client_id: "bench-#{System.pid()}",
         session: nil,
         kind: :term,
         size: %{cols: cols, rows: rows},
         cell_px: nil,
         caps: %{},
         target: :session
       }}
    )

    st = new(conn)
    wait_for(st, 60_000, fn st -> st.attached and st.rows != %{} end)
  end

  def wait_for(st, ms, pred) do
    deadline = now() + ms * 1000
    loop(st, deadline, pred)
  end

  defp loop(st, deadline, pred) do
    if pred.(st) do
      st
    else
      left = div(deadline - now(), 1000)
      left > 0 || raise "timed out waiting"

      case pump(st, left) do
        {:ok, st, _} -> loop(st, deadline, pred)
        {:timeout, _} -> raise "timed out waiting"
      end
    end
  end

  def pump_for(st, ms), do: pump_until(st, now() + ms * 1000)

  def key(st, text, mods \\ []) do
    ev = {:key, %{key: text, mods: mods, event: :press, text: if(mods == [], do: text)}}
    send_frame(st.conn, {:input, st.seq, ev})
    %{st | seq: st.seq + 1}
  end

  # one letter at a time to pane `id`; latencies in ms. Ctrl-U every 40 keys keeps the line short.
  def typing(st, id, keys, letter \\ ?x) do
    text = <<letter>>

    Enum.reduce(1..keys, {st, []}, fn i, {st, acc} ->
      st = if rem(i, 40) == 0, do: st |> key("u", [:ctrl]) |> settle(), else: st
      want = count(st, id, letter) + 1
      t0 = now()
      st = key(st, text)
      {st, t1} = await_count(st, id, letter, want, 30_000)
      {st |> pump_for(10), [(t1 - t0) / 1000 | acc]}
    end)
    |> then(fn {st, acc} -> {st, Enum.sort(acc)} end)
  end

  defp settle(st), do: pump_for(st, 300)

  defp await_count(st, id, letter, want, ms) do
    deadline = now() + ms * 1000

    Stream.repeatedly(fn -> nil end)
    |> Enum.reduce_while(st, fn _, st ->
      left = div(deadline - now(), 1000)
      left > 0 || raise "key not echoed in #{ms} ms"

      case pump(st, left) do
        {:ok, st, t} -> if count(st, id, letter) >= want, do: {:halt, {st, t}}, else: {:cont, st}
        {:timeout, _} -> raise "key not echoed in #{ms} ms"
      end
    end)
  end

  def pct(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, ceil(length(sorted) * p) - 1))
  def f(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)

  def typing_line(tag, tr, lat) do
    IO.puts(
      "REMOTE #{tag} transport=#{tr} n=#{length(lat)} p50=#{f(pct(lat, 0.5))} p95=#{f(pct(lat, 0.95))} " <>
        "max=#{f(List.last(lat))} load=#{load()}"
    )
  end

  # reads for `secs`; per-second {bytes, frames}
  def flood(st, secs) do
    t0 = now()

    {st, buckets} =
      Enum.reduce(1..secs, {st, []}, fn i, {st, acc} ->
        {b0, f0} = {st.bytes, st.frames}
        st = pump_until(st, t0 + i * 1_000_000)
        {st, [{st.bytes - b0, st.frames - f0} | acc]}
      end)

    {st, Enum.reverse(buckets)}
  end

  def pump_until(st, t_end) do
    left = div(t_end - now(), 1000)

    if left <= 0 do
      st
    else
      case pump(st, left) do
        {:ok, st, _} -> pump_until(st, t_end)
        {:timeout, st} -> st
      end
    end
  end

  def frame_ms do
    cfg = Path.join(@live, "config/config.exs") |> File.read!()

    case Regex.run(~r/client_socket.*?frame_ms:\s*(\d+)/s, cfg) do
      [_, ms] -> "#{ms} (config/config.exs default; no per-run override)"
      _ -> "unknown"
    end
  end

  # 14 panes split off in a heap pattern, directions alternating by the parent's split count
  def split_panes(b, first, total) do
    {ids, _} =
      Enum.reduce(1..(total - 1), {[first], %{}}, fn k, {ids, cnt} ->
        parent = Enum.at(ids, div(k - 1, 2))
        n = Map.get(cnt, parent, 0)
        dir = if rem(n, 2) == 0, do: "right", else: "down"
        out = cli(b, ["pane", "split", "p#{parent}", "--direction", dir])
        {ids ++ [pane_id(out)], Map.put(cnt, parent, n + 1)}
      end)

    ids
  end
end

alias RemoteBench, as: R

[transport | opts] = System.argv()
System.put_env("BENCH_TRANSPORT", transport)

opts =
  Map.new(opts, fn o ->
    [k, v] = String.split(o, "=", parts: 2)
    {k, v}
  end)

geti = fn k, d -> String.to_integer(opts[k] || "#{d}") end
keys = geti.("keys", 200)
secs = geti.("flood", 20)
mb = geti.("mb", 100)
panes = geti.("panes", 15)
only = opts["only"]

run = fn b ->
  IO.puts(
    "REMOTE config transport=#{transport} frame_ms=#{R.frame_ms()} keys=#{keys} flood_s=#{secs} mb=#{mb} panes=#{panes}"
  )

  b[:remote] || File.exists?(Path.join(b.root, "ctl.sock")) ||
    D.wait(fn -> File.exists?(Path.join(b.root, "ctl.sock")) end, 60_000)

  first = R.cli(b, ["pane", "list"]) |> R.pane_id()
  conn = R.connect(b, transport)
  st = R.attach(conn, 200, 50)
  id = hd(R.pane_ids(st))
  id == first || IO.puts("note: scene pane #{id}, api pane #{first}")
  # wait for a prompt: something drawn in the pane, then let the shell settle
  st = R.wait_for(st, 60_000, &R.drawn?(&1, id)) |> R.pump_for(1000)

  st =
    if only == "flood" do
      st
    else
      {st, lat} = R.typing(st, id, keys)
      R.typing_line("typing", transport, lat)
      st |> R.key("u", [:ctrl]) |> R.pump_for(300)
    end

  st =
    if only == "typing" do
      st
    else
      file = Path.join(b.root, "flood.txt")

      {_, 0} =
        R.on_server(
          "yes 'the quick brown fox jumps over the lazy dog 0123456789' 2>/dev/null | head -c #{mb * 1_048_576} > #{file}"
        )

      ids = R.split_panes(b, first, panes)
      for p <- tl(ids), do: R.cli(b, ["pane", "run", "p#{p}", "while :; do cat #{file}; done"])
      st = R.pump_for(st, 2000)
      {st, buckets} = R.flood(st, secs)
      mbs = Enum.map(buckets, fn {by, _} -> by / 1_048_576 end)
      frames = Enum.map(buckets, fn {_, fr} -> fr end)
      avg = &(Enum.sum(&1) / length(&1))

      IO.puts(
        "REMOTE flood transport=#{transport} panes=#{length(ids)} mean_mbs=#{R.f(avg.(mbs))} " <>
          "frames_s=#{R.f(avg.(frames))} peak_mbs=#{R.f(Enum.max(mbs))} secs=#{secs} load=#{R.load()}"
      )

      # the original pane (no cat) stays the focused one
      id in R.pane_ids(st) || IO.puts("note: typing pane #{id} not in scene")
      {st, lat} = R.typing(st, id, keys)
      R.typing_line("typing_flood", transport, lat)
      st
    end

  R.close(st.conn)
  :ok
end

IO.puts("REMOTE uptime_start #{R.uptime()}")

code =
  try do
    case if(R.server_root(),
           do: {run.(%{root: R.server_root(), remote: true}), 0},
           else: D.with_broker("remote", run)
         ) do
      {:ok, 0} ->
        0

      {_, st} ->
        IO.puts("REMOTE fail broker exit #{inspect(st)}")
        1
    end
  catch
    kind, reason ->
      IO.puts("REMOTE fail #{Exception.format(kind, reason, __STACKTRACE__)}")
      1
  end

IO.puts("REMOTE uptime_end #{R.uptime()}")
System.halt(code)
