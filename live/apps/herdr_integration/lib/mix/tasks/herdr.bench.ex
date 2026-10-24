# Test-only: drives clients with HerdrIntegration.Driver (test/support), and Mix is not
# in the dev PLT. Outside MIX_ENV=test the task does not exist.
if Mix.env() == :test do
  defmodule Mix.Tasks.Herdr.Bench do
    @shortdoc "Runs the herdr-live M3 benchmarks (MIX_ENV=test, fake kernel)"
    @moduledoc """
    M3 benchmark harness behind `just live-bench`. Everything runs against
    `Kernel.Fake`, so it measures the Elixir side only; targets are judged at M6.

      1. keystroke -> glass, idle, fast path and forced slow path
      2. frame cost (`Compose.frame/3` + `Fake.Blit.frame/3`) at 200x50, 1 vs 15 full panes
      3. scheduler stall and typing latency while 15 panes each get 100MiB of output

    Prints a markdown table and writes `_build/bench/m3.json` (quick runs:
    `m3-quick.json`). `--quick` (or `HERDR_BENCH_QUICK=1`) shrinks every metric
    10x. Compiled only in `:test` because it drives the clients with
    `HerdrIntegration.Driver` (test/support).
    """
    use Mix.Task

    alias HerdrIntegration.Driver
    alias HerdrScene.{Cell, Protocol}
    alias HerdrServer.Kernel.Fake.{Keeper, Pty}
    alias HerdrTerm.Client
    alias HerdrTerm.Client.Term.Render.Compose
    alias HerdrTerm.Client.Term.Theme
    alias HerdrTerm.Kernel.Fake.{Blit, Tty}

    @size {200, 50}
    @chunk 65_536
    @key_timeout_ms 5000
    @mailbox_limit 100

    @impl Mix.Task
    def run(args) do
      Mix.Task.run("app.start")
      quick? = "--quick" in args or System.get_env("HERDR_BENCH_QUICK") == "1"
      s = if quick?, do: 10, else: 1

      cfg = %{
        quick: quick?,
        keys: div(1000, s),
        warmup: div(20, s),
        iters: div(200, s),
        flood_bytes: div(100 * 1024 * 1024, s),
        flood_min_keys: div(200, s)
      }

      Driver.reset()
      client = start_client(@size)

      result =
        try do
          measure(client, cfg)
        after
          Supervisor.stop(client)
          Driver.reset()
        end

      report(result, cfg)
    end

    defp measure(client, cfg) do
      [pane] = Driver.scene(client).panes
      fast = keystrokes(client, pane, cfg.keys)
      slow = slow_path(fn -> keystrokes(client, pane, cfg.keys) end)
      paced = type_loop(client, pane, &(&1 >= cfg.keys), :paced)
      frame_1 = frame_cost(Driver.scene(client), cfg)
      frame_15 = frame_cost(Driver.grow(client, 15), cfg)

      %{
        fast: fast,
        slow: slow,
        paced: paced,
        frame_1: frame_1,
        frame_15: frame_15,
        stall: stall(client, cfg)
      }
    end

    # -- keystroke -> glass -------------------------------------------------

    defp start_client({cols, rows}) do
      {:ok, sup} = Client.start_link(id: make_ref(), tty_opts: [size: {cols, rows, 0, 0}])
      until(fn -> Driver.scene(sup) != nil and Blit.frames(Driver.tty(sup)) != [] end, 2000)
      # quiesce subscribes this process to the tty's frames (once, via the Driver)
      :ok = Driver.quiesce(sup)
      sup
    end

    defp until(check, left) do
      cond do
        check.() ->
          :ok

        left <= 0 ->
          Mix.raise("bench: client did not come up")

        true ->
          Process.sleep(5)
          until(check, left - 5)
      end
    end

    # Forces the slow path by publishing the fast-path term with passthrough false
    # (re-asserted before each keystroke in case the Store republished), then restores it.
    defp slow_path(fun) do
      key = Protocol.fast_path_key()
      orig = :persistent_term.get(key)
      slow = %{orig | passthrough: false}
      Process.put({__MODULE__, :before}, {key, slow})

      try do
        fun.()
      after
        Process.delete({__MODULE__, :before})
        :persistent_term.put(key, orig)
      end
    end

    defp before_key do
      case Process.get({__MODULE__, :before}) do
        {key, slow} -> :persistent_term.get(key, nil) == slow or :persistent_term.put(key, slow)
        nil -> :ok
      end
    end

    defp keystrokes(client, pane, n), do: type_loop(client, pane, &(&1 >= n), :idle)

    # Types one char at a time on the pane's first row (clearing the pane when the
    # row is full) until `stop?.(count)`. Each sample waits for its frame; `:idle` then
    # waits until no frame came for longer than the client's frame pacing (a keystroke
    # makes two frames: rows, then the cursor scene), `:paced` does not; both sleep 2ms.
    defp type_loop(client, pane, stop?, mode),
      do: type_loop(client, pane, {stop?, mode}, pane.rect.w, [], 0)

    defp type_loop(client, pane, {stop?, mode} = how, col, acc, done) do
      cond do
        stop?.(done) ->
          summarize(acc)

        col >= pane.rect.w - 1 ->
          clear(client, pane)
          type_loop(client, pane, how, 0, acc, done)

        true ->
          sample = keystroke(client, pane, col, <<?a + rem(done, 26)>>)
          if mode == :idle, do: quiet(Driver.tty(client))
          Process.sleep(2)
          type_loop(client, pane, how, col + 1, [sample | acc], done + 1)
      end
    end

    defp keystroke(client, %{rect: r}, col, ch) do
      tty = Driver.tty(client)
      drain(tty)
      before_key()
      t0 = :erlang.monotonic_time(:nanosecond)
      Driver.type(client, ch)

      case await_cell(tty, {r.x + col, r.y}, [ch], deadline()) do
        :timeout -> :timeout
        at when at < t0 -> :invalid
        at -> (at - t0) / 1000
      end
    end

    defp clear(client, %{id: id, rect: r}) do
      tty = Driver.tty(client)
      drain(tty)
      Driver.output(id, "\e[2J\e[1;1H")
      :timeout != await_cell(tty, {r.x, r.y}, ["", " "], deadline()) or Mix.raise("bench: clear")
    end

    # On each frame notification, reads the cell and the latest logged frame's `at` in one
    # Agent read and returns that `at` once the cell holds one of `want`. `Fake.Blit` writes
    # the screen before notifying, so the screen may already include later frames; the
    # latest `at` is the frame that is certainly shown, an upper bound on the true latency.
    defp await_cell(tty, {x, y}, want, deadline) do
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:frame, ^tty, _} ->
          {glyph, at} = cell(tty, x, y)
          if glyph in want and at != nil, do: at, else: await_cell(tty, {x, y}, want, deadline)
      after
        left -> :timeout
      end
    end

    defp cell(tty, x, y) do
      {row, last} = Agent.get(tty, &{Map.get(&1.screen, y), :queue.peek_r(&1.frames)})
      at = if match?({:value, _}, last), do: elem(last, 1).at

      case row do
        nil -> {nil, at}
        row -> {row |> Cell.slice(x, 1) |> Cell.decode_row() |> hd() |> Map.fetch!(:glyph), at}
      end
    end

    defp quiet(tty) do
      receive do
        {:frame, ^tty, _} -> quiet(tty)
      after
        Application.get_env(:herdr_term, :min_frame_interval_ms, 6) + 2 -> :ok
      end
    end

    defp drain(tty) do
      receive do
        {:frame, ^tty, _} -> drain(tty)
      after
        0 -> :ok
      end
    end

    defp deadline, do: System.monotonic_time(:millisecond) + @key_timeout_ms

    # -- frame cost ---------------------------------------------------------

    defp frame_cost(scene, cfg) do
      {cols, rows} = @size
      {:ok, tty} = Tty.open(size: {cols, rows, 0, 0})
      theme = Theme.default()
      full = full_rows(scene, "x")
      alt = full_rows(scene, "y")
      [%{id: one} | _] = scene.panes

      blit = fn rows, repaint ->
        Blit.frame(tty, Compose.frame(scene, rows, theme), %{
          cursor: nil,
          shape: :block,
          repaint: repaint
        })
      end

      repaint = time(cfg, fn _ -> blit.(full, true) end)

      dirty =
        time(cfg, fn i ->
          src = if rem(i, 2) == 0, do: alt, else: full
          blit.(Map.put(full, one, src[one]), false)
        end)

      Agent.stop(tty)
      %{panes: length(scene.panes), repaint: repaint, dirty: dirty}
    end

    # every row of every pane full of text; one packed row per width, built once
    defp full_rows(scene, glyph) do
      Map.new(scene.panes, fn %{id: id, rect: r} ->
        row = Cell.encode_row(List.duplicate(%Cell{glyph: glyph}, r.w))
        {id, Tuple.duplicate(row, r.h)}
      end)
    end

    defp time(cfg, fun) do
      Enum.each(1..cfg.warmup//1, fun)

      samples =
        for i <- 1..cfg.iters do
          t0 = :erlang.monotonic_time(:nanosecond)
          fun.(i)
          (:erlang.monotonic_time(:nanosecond) - t0) / 1000
        end

      summarize(samples)
    end

    # -- stall under flood --------------------------------------------------

    defp stall(client, cfg) do
      [typed | flooded] = client |> Driver.grow(16) |> Map.fetch!(:panes)
      Driver.click(client, typed.id)
      :ok = Driver.quiesce(client)

      line = String.duplicate("0123456789abcdef", 4) <> "\r\n"
      chunk = binary_part(:binary.copy(line, div(@chunk, byte_size(line)) + 1), 0, @chunk)
      chunks = div(cfg.flood_bytes, @chunk)

      collector = spawn_link(&collect/0)
      prev = :erlang.system_monitor(collector, [{:long_schedule, 5}, {:long_gc, 5}])
      probe = spawn_link(fn -> probe(0) end)
      t0 = System.monotonic_time(:millisecond)

      try do
        feeders =
          Enum.map(flooded, fn %{id: id} -> Task.async(fn -> feed(id, chunk, chunks) end) end)

        stop? = &(&1 >= cfg.flood_min_keys and done?(feeders))
        typing = type_loop(client, typed, stop?, :paced)
        throttled = feeders |> Task.await_many(:infinity) |> Enum.sum()
        wall = System.monotonic_time(:millisecond) - t0

        %{
          panes: length(flooded),
          bytes_per_pane: chunks * @chunk,
          wall_ms: wall,
          throttle_sleeps: throttled,
          typing: typing,
          probe_max_ms: stop(probe) / 1000,
          monitor: stop(collector)
        }
      after
        restore_monitor(prev)
      end
    end

    defp done?(tasks), do: not Enum.any?(tasks, &Process.alive?(&1.pid))

    defp restore_monitor({pid, opts}), do: :erlang.system_monitor(pid, opts)
    defp restore_monitor(:undefined), do: :erlang.system_monitor(:undefined)

    # Fake.Pty applies no backpressure; yield 1ms while its or the vt's mailbox is deep.
    defp feed(id, chunk, n) do
      {:ok, %{pty: pty, vt: vt}} = Keeper.lookup(id)

      Enum.reduce(1..n//1, 0, fn _, sleeps ->
        sleeps = throttle(pty, vt, sleeps)
        Pty.output(pty, chunk)
        sleeps
      end)
    end

    defp throttle(pty, vt, sleeps) do
      if qlen(pty) + qlen(vt) > @mailbox_limit do
        Process.sleep(1)
        throttle(pty, vt, sleeps + 1)
      else
        sleeps
      end
    end

    defp qlen(pid) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> n
        nil -> 0
      end
    end

    # max overshoot (µs) of Process.sleep(1)
    defp probe(max) do
      receive do
        {:stop, from} -> send(from, {:stopped, self(), max})
      after
        0 ->
          t0 = System.monotonic_time(:microsecond)
          Process.sleep(1)
          probe(max(max, System.monotonic_time(:microsecond) - t0 - 1000))
      end
    end

    defp collect, do: collect(%{long_schedule: [], long_gc: []})

    defp collect(acc) do
      receive do
        {:monitor, _who, kind, info} when kind in [:long_schedule, :long_gc] ->
          collect(Map.update!(acc, kind, &[{Keyword.get(info, :timeout, 0), info[:in]} | &1]))

        {:stop, from} ->
          send(from, {:stopped, self(), Map.new(acc, fn {k, ms} -> {k, events(ms)} end)})

        _ ->
          collect(acc)
      end
    end

    defp events(evs) do
      {max, at} = Enum.max_by(evs, &elem(&1, 0), fn -> {0, nil} end)
      %{count: length(evs), max_ms: max, max_in: inspect(at)}
    end

    defp stop(pid) do
      send(pid, {:stop, self()})

      receive do
        {:stopped, ^pid, value} -> value
      end
    end

    # -- stats and output ---------------------------------------------------

    defp summarize(samples) do
      {ok, bad} = Enum.split_with(samples, &is_number/1)
      sorted = Enum.sort(ok)
      n = length(sorted)

      %{
        n: n,
        timeouts: Enum.count(bad, &(&1 == :timeout)),
        invalid: Enum.count(bad, &(&1 == :invalid)),
        mean: if(n > 0, do: Enum.sum(sorted) / n, else: 0.0),
        p50: pct(sorted, n, 50),
        p95: pct(sorted, n, 95),
        p99: pct(sorted, n, 99),
        max: List.last(sorted) || 0.0
      }
    end

    # nearest rank
    defp pct(_sorted, 0, _p), do: 0.0
    defp pct(sorted, n, p), do: Enum.at(sorted, max(ceil(p * n / 100) - 1, 0))

    defp report(r, cfg) do
      %{frame_1: f1, frame_15: f15, stall: st} = r
      ratio = f15.repaint.mean / f1.repaint.mean

      json = %{
        keystroke_fast_p95_us: r.fast.p95,
        keystroke_slow_p95_us: r.slow.p95,
        frame_1_mean_us: f1.repaint.mean,
        frame_15_mean_us: f15.repaint.mean,
        frame_ratio: ratio,
        stall_probe_max_ms: st.probe_max_ms,
        long_schedule_count: st.monitor.long_schedule.count,
        typing_during_flood_p95_us: st.typing.p95,
        quick: cfg.quick,
        keystroke_fast: r.fast,
        keystroke_slow: r.slow,
        keystroke_paced: r.paced,
        frame_1: f1,
        frame_15: f15,
        stall: st,
        environment: environment()
      }

      name = if cfg.quick, do: "bench/m3-quick.json", else: "bench/m3.json"
      path = Mix.Project.build_path() |> Path.dirname() |> Path.join(name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(json))
      Mix.shell().info(table(r, ratio, cfg))
      Mix.shell().info("\nwrote #{Path.relative_to_cwd(path)}")
    end

    defp table(r, ratio, cfg) do
      %{frame_1: f1, frame_15: f15, stall: st} = r
      env = environment()

      """
      ## herdr-live M3 bench: against Kernel.Fake: Elixir side only; targets judged at M6

      #{if cfg.quick, do: "**QUICK run (every metric 10x smaller)**\n", else: ""}
      | metric | value | target (design.md, judged at M6) |
      |---|---|---|
      | keystroke -> glass idle, fast path (n=#{r.fast.n}) | #{keys(r.fast)} | <= herdr + 1ms p95 |
      | keystroke -> glass idle, slow path (n=#{r.slow.n}) | #{keys(r.slow)} | <= herdr + 1ms p95 |
      | keystroke -> glass, 2ms after each frame, fast path (n=#{r.paced.n}) | #{keys(r.paced)} | reference |
      | frame cost 200x50, 1 full pane (repaint) | #{frame(f1.repaint)} | |
      | frame cost 200x50, #{f15.panes} full panes (repaint) | #{frame(f15.repaint)} | |
      | frame cost ratio #{f15.panes}/1 (mean) | #{fmt(ratio)}x | within 2x herdr's ratio |
      | frame cost 200x50, #{f15.panes} panes, 1 pane dirty (full compose, no repaint) | #{frame(f15.dirty)} | reference |
      | flood: #{st.panes} panes x #{div(st.bytes_per_pane, 1024 * 1024)}MiB, wall time | #{st.wall_ms} ms | |
      | flood: Process.sleep(1) probe max overshoot | #{fmt(st.probe_max_ms)} ms | no stall > 10ms |
      | flood: long_schedule >= 5ms events (max) | #{st.monitor.long_schedule.count} (#{st.monitor.long_schedule.max_ms} ms in #{st.monitor.long_schedule.max_in}) | |
      | flood: long_gc >= 5ms events (max) | #{st.monitor.long_gc.count} (#{st.monitor.long_gc.max_ms} ms) | |
      | flood: typing in a 16th pane (n=#{st.typing.n}) | #{keys(st.typing)} | <= 20ms |

      Method: keystroke t0 = monotonic time before `Fake.Tty.inject` of one printable char;
      t1 = `at` of the latest logged `Fake.Blit` frame when the target cell first shows it
      (read together; an upper bound), samples with t1 < t0 are counted invalid.
      One keystroke at a time, waiting for its frame. Idle rows then wait until no frame for
      min_frame_interval_ms + 2ms (each keystroke yields a rows frame then a cursor-scene
      frame), then 2ms; the "2ms after each frame" row and flood typing only sleep 2ms, so
      the second frame's pacing delays the next key's frame. Slow path = fast-path
      `:persistent_term` republished with `passthrough: false` (re-asserted before each key),
      so keys go client Input -> Client.Session -> App.Store. Client frames are paced at
      min_frame_interval_ms. Frame cost = `Compose.frame/3` + `Fake.Blit.frame/3`,
      #{cfg.warmup} warmup + #{cfg.iters} iterations, on a dedicated fake tty. Flood = 15
      feeder processes pushing 64KiB chunks of one binary via `Fake.Pty.output/2`; the fake
      applies no real backpressure, feeders sleep 1ms while pty+vt mailboxes exceed
      #{@mailbox_limit} (#{st.throttle_sleeps} sleeps); the fake vt keeps only the tail of each chunk.

      Environment: OTP #{env.otp}, Elixir #{env.elixir}, #{env.schedulers} schedulers, #{env.os}
      """
    end

    defp keys(s) do
      t = if s.timeouts > 0, do: ", #{s.timeouts} timeouts", else: ""
      t = if s.invalid > 0, do: t <> ", #{s.invalid} invalid (frame at < t0)", else: t
      "p50 #{us(s.p50)} / p95 #{us(s.p95)} / p99 #{us(s.p99)} / max #{us(s.max)} µs#{t}"
    end

    defp frame(s), do: "mean #{us(s.mean)} / p95 #{us(s.p95)} µs"
    defp us(v), do: round(v)
    defp fmt(v), do: :erlang.float_to_binary(v / 1, decimals: 2)

    defp environment do
      {family, name} = :os.type()

      %{
        otp: System.otp_release(),
        elixir: System.version(),
        schedulers: System.schedulers_online(),
        os: "#{family}/#{name} #{:os.version() |> Tuple.to_list() |> Enum.join(".")}",
        arch: :erlang.system_info(:system_architecture) |> to_string()
      }
    end
  end
end
