defmodule HandoffDriver do
  @moduledoc """
  Drives a headless `bin/herdr-live` through its broker socket for the M5
  handoff smoke and benches (plain `elixir` scripts, no Mix). Frames per
  docs/herdr-live/plans/m5.md "Wire protocol": `len: u32 | kind | nfds | body`.
  """

  @live Path.expand("../..", __DIR__)
  @ctl_restart 0x81
  @ctl_status 0x82
  @ctl_request 0x83
  @ctl_result 0xC1
  @ctl_status_reply 0xC2
  @ctl_reply 0xC3

  def dynide_dir, do: @live

  @doc "The launcher under test: $HERDR_LIVE_BENCH_BIN (an installed release) else dynide/bin/herdr-live (not $HERDR_LIVE_BIN: a pane exports that, so a bench run inside a pane would drive the dogfood instance)."
  def bin do
    case System.get_env("HERDR_LIVE_BENCH_BIN") do
      b when b in [nil, ""] -> Path.join(@live, "bin/herdr-live")
      b -> Path.expand(b)
    end
  end

  @doc "PATH for the VMs and panes: the caller's plus Homebrew (htop on macOS)."
  def path, do: System.get_env("PATH", "/usr/bin:/bin") <> ":/opt/homebrew/bin:/usr/local/bin"

  @doc """
  Boots the launcher (`bin/0`) headless under `/tmp/hl-<tag>-<our os pid>` (runtime and log
  dir unique per run, so concurrent runs never share a socket) and waits for a primary.
  """
  def start_broker(tag) do
    dir = "/tmp/hl-#{tag}-#{System.pid()}"
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    log = Path.join(dir, "herdr-live.log")
    # M13: a fresh config opens the first-run onboarding modal, which takes every key
    config = Path.join(dir, "config.toml")
    File.write!(config, "onboarding = false\n")

    env = [
      {~c"HERDR_LIVE_HEADLESS", ~c"1"},
      {~c"HERDR_LIVE_RUNTIME_DIR", String.to_charlist(Path.join(dir, "rt"))},
      {~c"HERDR_LIVE_LOG", String.to_charlist(log)},
      # session files (M8) under the run dir, never the real session
      {~c"HERDR_LIVE_STATE_DIR", String.to_charlist(Path.join(dir, "state"))},
      {~c"HERDR_LIVE_SESSION", false},
      {~c"HERDR_LIVE_PERSIST", false},
      {~c"HERDR_LIVE_API", String.to_charlist(Path.join(dir, "ctl.sock"))},
      {~c"HERDR_LIVE_CONFIG", String.to_charlist(config)},
      {~c"PATH", String.to_charlist(path())},
      {~c"HERDR_SOCKET_PATH", false},
      {~c"HERDR_CLIENT_SOCKET_PATH", false},
      {~c"HERDR_BROKER_SOCK", false},
      {~c"MIX_ENV", false}
    ]

    port =
      Port.open({:spawn_executable, bin()}, [
        :binary,
        :exit_status,
        env: env
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    b = %{dir: Path.join(dir, "rt"), root: dir, log: log, os_pid: os_pid, port: port}

    try do
      wait(fn -> match?(%{"primary_gen" => g} when g != "-", status(b.dir)) end, 600_000)
    rescue
      e ->
        stop_broker(b)
        outlived(vm_pids(b))
        IO.puts(:stderr, "broker did not start; log tail:\n" <> tail(log))
        reraise e, __STACKTRACE__
    end

    b
  end

  @doc """
  Runs `fun.(broker)` and always stops the broker afterwards:
  `{fun_result, broker_exit_status}`, where the status is `{:outlived, pids}` when a VM
  or pane child outlived the stop (they are killed then), or the failure re-raised
  after the stop (log tail on stderr). The run dir is removed after a clean run.
  """
  def with_broker(tag, fun) do
    b = start_broker(tag)

    r =
      try do
        fun.(b)
      catch
        kind, reason ->
          stop_broker(b)
          outlived(vm_pids(b))
          IO.puts(:stderr, "log tail (#{b.log}):\n" <> tail(b.log))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    panes = pane_pids(b)

    case {r, stop_broker(b), outlived(vm_pids(b) ++ panes)} do
      {r, st, []} ->
        keep(b)
        if st == 0 and not keep?(), do: File.rm_rf(b.root)
        {r, st}

      {r, _st, left} ->
        IO.puts(:stderr, "outlived the broker stop: #{inspect(left)}; log #{b.log}")
        {r, {:outlived, left}}
    end
  end

  # ---- evidence (HERDR_BENCH_KEEP=1) ----

  @doc "HERDR_BENCH_KEEP=1: keep the run dir and copy its log to HERDR_BENCH_KEEP_DIR."
  def keep?, do: System.get_env("HERDR_BENCH_KEEP") == "1"

  defp keep(b) do
    with true <- keep?(), dir when is_binary(dir) <- System.get_env("HERDR_BENCH_KEEP_DIR") do
      File.mkdir_p!(dir)
      dest = Path.join(dir, "#{Path.basename(b.root)}-herdr-live.log")
      File.cp!(b.log, dest)
      IO.puts("KEEP log=#{dest}")
    else
      _ -> keep?() && IO.puts("KEEP log=#{b.log}")
    end
  end

  @doc "Log size now: pass to `phases/3` to read only what a run logged."
  def log_mark(b), do: (File.stat(b.log) |> elem(1)).size

  @doc "Wall clock now as ms of the UTC day (the broker log's clock)."
  def day_ms, do: rem(System.os_time(:millisecond), 86_400_000)

  @doc """
  The handoff steps logged since `mark`, as `[{step, ms_since_kill, text}]`. Broker
  lines carry UTC `HH:MM:SS.mmm`; VM Logger lines carry local time, so those are
  aligned modulo one hour (whole-hour zone offsets).
  """
  def phases(b, mark, kill_ms) do
    all = File.read!(b.log)
    text = binary_part(all, mark, byte_size(all) - mark)

    for line <- String.split(text, "\n"),
        [_, h, m, sec, ms, rest] <- [Regex.run(~r/(\d\d):(\d\d):(\d\d)\.(\d{3}) (.*)$/, line)],
        step = step(rest),
        step != nil do
      t =
        ((String.to_integer(h) * 60 + String.to_integer(m)) * 60 + String.to_integer(sec)) * 1000 +
          String.to_integer(ms)

      d =
        if String.starts_with?(rest, "dynide-broker:"),
          do: wrap(t - kill_ms, 86_400_000),
          else: wrap(rem(t, 3_600_000) - rem(kill_ms, 3_600_000), 3_600_000)

      {step, d, String.trim(rest)}
    end
  end

  defp wrap(d, m) when d > div(m, 2), do: d - m
  defp wrap(d, m) when d < -div(m, 2), do: d + m
  defp wrap(d, _), do: d

  @steps [
    {"role=standby", :standby},
    {"link closed", :eof},
    {"died status", :died},
    {"started vm", :spawn},
    {"preloaded", :preloaded},
    {"adopt sent", :adopt},
    {"crash entries", :link_up},
    {"handoff failed", :failed},
    {"handoff crash", :restored},
    {"is primary", :primary},
    {"herdr-live started", :started}
  ]

  defp step(rest) do
    Enum.find_value(@steps, fn {needle, step} -> String.contains?(rest, needle) && step end)
  end

  @doc "One line: `step=ms` in log order (first of each step)."
  def phase_line(ph),
    do: ph |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map_join(" ", fn {s, d, _} -> "#{s}=#{d}" end)

  # every pane child still known to the primary
  defp pane_pids(b) do
    c = connect(b.dir)

    try do
      Enum.map(request(c, :panes), fn {_id, p} -> "#{p}" end)
    after
      :gen_tcp.close(c)
    end
  rescue
    _ -> []
  end

  # pids still alive 3 s after the stop (SIGHUP'd children need a moment), then killed
  defp outlived(pids) do
    try do
      wait(fn -> not Enum.any?(pids, &alive?/1) end, 3_000, 50)
      []
    rescue
      _ ->
        left = Enum.filter(pids, &alive?/1)
        for p <- left, do: System.cmd("kill", ["-KILL", p], stderr_to_stdout: true)
        left
    end
  end

  def connect(dir) do
    {:ok, s} =
      :gen_tcp.connect({:local, String.to_charlist(Path.join(dir, "broker.sock"))}, 0, [
        :binary,
        active: false,
        packet: :raw
      ])

    s
  end

  @doc "Broker status as a map of strings (`dir` or an open ctl connection)."
  def status(dir) when is_binary(dir) do
    case :gen_tcp.connect({:local, String.to_charlist(Path.join(dir, "broker.sock"))}, 0, [
           :binary,
           active: false,
           packet: :raw
         ]) do
      {:ok, s} ->
        try do
          status(s)
        after
          :gen_tcp.close(s)
        end

      {:error, _} ->
        %{}
    end
  end

  def status(conn) do
    :ok = send_frame(conn, @ctl_status, "")
    {@ctl_status_reply, text} = recv_frame(conn, 5_000)

    for line <- String.split(text, "\n", trim: true), into: %{} do
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end
  end

  @doc "One ctl request, one reply (ETF both ways)."
  def request(conn, term) do
    send_request(conn, term)
    recv_reply(conn)
  end

  def send_request(conn, term), do: send_frame(conn, @ctl_request, :erlang.term_to_binary(term))

  def recv_reply(conn, timeout \\ 30_000) do
    {@ctl_reply, body} = recv_frame(conn, timeout)
    :erlang.binary_to_term(body)
  end

  @doc "Graceful `kernel-restart`: `{ok?, text}`."
  def restart(dir) do
    s = connect(dir)

    try do
      :ok = send_frame(s, @ctl_restart, "")
      {@ctl_result, <<ok, text::binary>>} = recv_frame(s, :infinity)
      {ok == 1, text}
    after
      :gen_tcp.close(s)
    end
  end

  @doc "Polls `fun` every 10 ms until it returns a truthy value; raises after `timeout_ms`."
  def wait(fun, timeout_ms, every \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, every)
  end

  defp do_wait(fun, deadline, every) do
    case fun.() do
      v when v in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline, do: raise("wait timed out")
        Process.sleep(every)
        do_wait(fun, deadline, every)

      v ->
        v
    end
  end

  @doc "SIGTERM and wait for the broker's exit status (`:killed` after 30 s)."
  def stop_broker(%{port: port} = b) do
    System.cmd("kill", ["-TERM", "#{b.os_pid}"], stderr_to_stdout: true)

    st =
      receive do
        {^port, {:exit_status, st}} -> st
      after
        30_000 ->
          System.cmd("kill", ["-KILL", "#{b.os_pid}"], stderr_to_stdout: true)
          :killed
      end

    st
  end

  @doc "Every VM pid the broker logged as started."
  def vm_pids(b) do
    case File.read(b.log) do
      {:ok, text} ->
        for [_, p] <- Regex.scan(~r/dynide-broker: started vm .* pid=(\d+) /, text), do: p

      _ ->
        []
    end
  end

  def alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  def tail(path) do
    case File.read(path) do
      {:ok, t} -> t |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")
      _ -> "(no log)"
    end
  end

  # ---- panes over ctl ----

  def open(conn, cmd, args, opts \\ []) do
    req = %{
      cmd: cmd,
      args: args,
      cols: Keyword.get(opts, :cols, 100),
      rows: Keyword.get(opts, :rows, 30),
      env: [{"TERM", "xterm-256color"}, {"PATH", path()}]
    }

    {:ok, id} = request(conn, {:open, req})
    id
  end

  def text(conn, id) do
    case request(conn, {:text, id}) do
      {:ok, t} -> t
      _ -> ""
    end
  end

  @doc "True once some line of the pane's text is exactly `line` (not the echoed command)."
  def has_line?(conn, id, line),
    do: conn |> text(id) |> String.split("\n") |> Enum.any?(&(String.trim_trailing(&1) == line))

  @doc "Types `echo <word>` and waits for the output line."
  def answers?(conn, id, word, timeout \\ 5_000) do
    :ok = request(conn, {:write, id, "echo #{word}\n"})

    try do
      wait(fn -> has_line?(conn, id, word) end, timeout, 20)
    rescue
      _ -> false
    end
  end

  def panes(conn), do: Map.new(request(conn, :panes))

  def now, do: System.monotonic_time(:microsecond) / 1000

  def percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))

  def uptime, do: elem(System.cmd("uptime", []), 0) |> String.trim()

  # ---- frames ----

  def send_frame(s, kind, body),
    do: :gen_tcp.send(s, [<<byte_size(body) + 2::32, kind, 0>>, body])

  def recv_frame(s, timeout) do
    {:ok, <<len::32>>} = :gen_tcp.recv(s, 4, timeout)
    {:ok, <<kind, _nfds, body::binary>>} = :gen_tcp.recv(s, len, timeout)
    {kind, body}
  end
end
