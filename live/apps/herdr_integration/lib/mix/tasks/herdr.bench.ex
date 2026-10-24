# Test-only: drives clients with HerdrIntegration.Driver (test/support), and Mix is not
# in the dev PLT. Outside MIX_ENV=test the task does not exist.
if Mix.env() == :test do
  defmodule Mix.Tasks.Herdr.Bench do
    @shortdoc "Runs the herdr-live M3 benchmarks (MIX_ENV=test; fake or real server kernel)"
    @moduledoc """
    M3 benchmark harness behind `just live-bench`. By default everything runs against
    `Kernel.Fake` (Elixir side only); `--kernel real` restarts herdr_server on M1's
    `HerdrServer.Native.*` with `/bin/sh` panes (the terminal client stays on its fakes
    until M2). Targets are judged at M6.

      1. keystroke -> glass, idle, fast path and forced slow path
      2. second client: a key typed in client A, timed until client B (80x24) shows it
      3. frame cost (`Compose.frame/4` + `Fake.Blit.frame/3`) at `--size`, 1 vs 15 full panes,
         and 15 panes under an open dimming modal (the rename prompt)
      4. scheduler stall and typing latency while 15 panes each get 100MiB of output

    Prints a markdown table and writes `_build/bench/m3.json` (`m3-real.json` with
    `--kernel real`, `-COLSxROWS` with a non-default `--size`, `-quick` suffix for quick
    runs). `--size COLSxROWS` (default 200x50, at least 60x20 for 16 panes) is client A's
    terminal and the frame-cost geometry. `--quick` (or `HERDR_BENCH_QUICK=1`)
    shrinks every metric 10x. `--flood-mb N` sets the bytes per flooded pane (MiB,
    default 100). `--compose raw|inline|budget` picks how frame cost calls Compose:
    `raw` (default) is M3's direct `Compose.frame/4` (chrome layout precomputed, as
    Render caches it); `inline` and `budget` go through
    `HerdrReload.Guard.run/4` on `Compose.screen/5` like Render, without and with its
    50ms budget (a worker per frame). With `--kernel real` the typed pane runs `cat` (tty echo) and each
    flooded pane runs `cat` of one generated file (in `HERDR_REAL_KERNEL_TMP`, default
    the system tmp dir). Compiled only in `:test` because it drives the clients with
    `HerdrIntegration.Driver` (test/support).
    """
    use Mix.Task

    alias HerdrIntegration.Driver
    alias HerdrScene.{Cell, Protocol}
    alias HerdrServer.App.{Modal, Store}
    alias HerdrServer.App.Modal.Prompt
    alias HerdrServer.Kernel
    alias HerdrServer.Kernel.Fake.{Keeper, Pty}
    alias HerdrServer.Pane.Rows
    alias HerdrTerm.Client
    alias HerdrTerm.Client.Term.Render.{Chrome, Compose}
    alias HerdrTerm.Client.Term.Theme
    alias HerdrTerm.Kernel.Fake.{Blit, Tty}

    @size {200, 50}
    @min_size {60, 20}
    @second_size {80, 24}
    @second_keys 200
    @chunk 65_536
    @key_timeout_ms 5000
    @mailbox_limit 100
    @flood_end "FLOOD-END"
    @flood_timeout_ms 120_000

    @impl Mix.Task
    def run(args) do
      Mix.Task.run("app.start")

      {opts, _, _} =
        OptionParser.parse(args,
          strict: [
            quick: :boolean,
            kernel: :string,
            flood_mb: :integer,
            compose: :string,
            size: :string
          ]
        )

      quick? = opts[:quick] == true or System.get_env("HERDR_BENCH_QUICK") == "1"
      s = if quick?, do: 10, else: 1
      kernel = if opts[:kernel] == "real", do: :real, else: :fake

      cfg = %{
        quick: quick?,
        kernel: kernel,
        keys: div(1000, s),
        warmup: div(20, s),
        iters: div(200, s),
        flood_bytes: div(Keyword.get(opts, :flood_mb, 100) * 1024 * 1024, s),
        flood_min_keys: div(200, s),
        compose: Keyword.get(opts, :compose, "raw"),
        size: size(opts[:size]),
        file: nil
      }

      cfg = if kernel == :real, do: real_kernel(cfg), else: cfg
      Driver.reset()
      client = start_client(cfg.size)
      if kernel == :real, do: exec_cat(client)

      result =
        try do
          measure(client, cfg)
        after
          Supervisor.stop(client)
          Driver.reset()
          if cfg.file, do: File.rm(cfg.file)
        end

      report(result, cfg)
    end

    defp size(nil), do: @size

    defp size(arg) do
      {min_cols, min_rows} = @min_size

      case Regex.run(~r/^(\d+)x(\d+)$/, arg) do
        [_, c, r] ->
          {cols, rows} = {String.to_integer(c), String.to_integer(r)}

          if cols < min_cols or rows < min_rows,
            do: Mix.raise("bench: --size too small (min #{min_cols}x#{min_rows})")

          {cols, rows}

        nil ->
          Mix.raise("bench: --size must be COLSxROWS, got #{inspect(arg)}")
      end
    end

    # Restarts herdr_server on the real kernel (Kernel.load reads the env at app start).
    # Children inherit the VM's OS environment, so PS1 goes through :pane_env.
    defp real_kernel(cfg) do
      :ok = Application.stop(:herdr_server)
      native = [vt: HerdrServer.Native.Vt, pty: HerdrServer.Native.Pty]
      Application.put_env(:herdr_server, :kernel, native ++ [keeper: HerdrServer.Native.Keeper])
      System.put_env("SHELL", "/bin/sh")

      Application.put_env(:herdr_server, :pane_env, [
        {"PS1", "$ "},
        {"BASH_SILENCE_DEPRECATION_WARNING", "1"}
      ])

      {:ok, _} = Application.ensure_all_started(:herdr_server)
      %{cfg | file: flood_file(cfg.flood_bytes)}
    end

    # one file of numbered 64-byte lines, `bytes` long, ending in a marker line
    defp flood_file(bytes) do
      dir = System.get_env("HERDR_REAL_KERNEL_TMP", System.tmp_dir!())
      path = Path.join(dir, "herdr-bench-flood-#{System.unique_integer([:positive])}")
      line = fn n -> String.pad_trailing(Integer.to_string(n), 62, ".") <> "\r\n" end
      lines = div(bytes, 64) - 1

      File.write!(
        path,
        Enum.map(1..lines//1, line) ++ [String.pad_trailing(@flood_end, 62) <> "\r\n"]
      )

      path
    end

    # the typed pane echoes keys through the tty line discipline: `exec cat` at the prompt
    defp exec_cat(client) do
      [%{id: id}] = Driver.scene(client).panes
      until(fn -> text(id) =~ "$" end, 5000)
      Driver.type(client, "exec cat\r")
      until(fn -> match?({_, _, %{x: 0, y: 1}}, Rows.fetch(id)) end, 5000)
      :ok = Driver.quiesce(client)
    end

    defp text(id) do
      {:ok, %{vt: vt}} = Kernel.keeper().lookup(Rows.kernel_id(id))
      Kernel.vt().read_text(vt, :viewport)
    end

    defp measure(client, cfg) do
      [pane] = Driver.scene(client).panes
      Process.put({__MODULE__, :kernel}, cfg.kernel)
      fast = keystrokes(client, pane, cfg.keys)
      slow = slow_path(fn -> keystrokes(client, pane, cfg.keys) end)
      paced = type_loop(client, pane, &(&1 >= cfg.keys), :paced)
      second = second_client(client, pane, cfg)
      frame_1 = frame_cost(Driver.scene(client), cfg)
      scene_15 = Driver.grow(client, 15)
      frame_15 = frame_cost(scene_15, cfg)
      frame_15_dim = frame_cost(with_prompt(scene_15), cfg)

      %{
        fast: fast,
        slow: slow,
        paced: paced,
        second: second,
        frame_1: frame_1,
        frame_15: frame_15,
        frame_15_dim: frame_15_dim,
        stall: stall(client, cfg)
      }
    end

    # -- keystroke -> glass -------------------------------------------------

    defp start_client({cols, rows}) do
      {:ok, sup} = Client.start_link(id: make_ref(), tty_opts: %{size: {cols, rows, 0, 0}})
      until(fn -> Driver.scene(sup) != nil and Blit.frames(Driver.tty(sup)) != [] end, 2000)
      # quiesce subscribes this process to the tty's frames (once, via the Driver)
      :ok = Driver.quiesce(sup)
      sup
    end

    defp until(check, left, what \\ "client did not come up") do
      cond do
        check.() ->
          :ok

        left <= 0 ->
          Mix.raise("bench: #{what}")

        true ->
          Process.sleep(5)
          until(check, left - 5, what)
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

    # Types one char at a time at the pane's cursor (from the row cache), clearing the
    # pane (fake) or pressing enter (real, `cat`) when the row is full, until
    # `stop?.(count)`. Each sample waits for its frame; `:idle` then waits until no frame
    # came for longer than the client's frame pacing (a keystroke makes one frame: rows
    # and cursor travel together), `:paced` does not; both sleep 2ms.
    # `view` is where samples are read: a tty, the pane's rect on it, and the cursor bounds
    # (default: client A's own frames and rect).
    defp type_loop(client, pane, stop?, mode, view \\ nil) do
      view = view || %{tty: Driver.tty(client), rect: pane.rect, w: pane.rect.w, h: pane.rect.h}
      loop(client, pane, {stop?, mode, view}, [], 0)
    end

    defp loop(client, pane, {stop?, mode, view} = how, acc, done) do
      {x, y} = at = cursor(pane)

      cond do
        stop?.(done) ->
          summarize(acc)

        x >= view.w - 1 or y >= view.h ->
          clear(client, pane, at)
          loop(client, pane, how, acc, done)

        true ->
          sample = keystroke(client, view, at, <<?a + rem(done, 26)>>)
          if mode == :idle, do: quiet(view.tty)
          Process.sleep(2)
          loop(client, pane, how, [sample | acc], done + 1)
      end
    end

    defp cursor(%{id: id}) do
      case Rows.fetch(id) do
        {_, _, %{x: x, y: y}} -> {x, y}
        _ -> {0, 0}
      end
    end

    defp keystroke(client, %{tty: tty, rect: r}, {x, y}, ch) do
      drain(Driver.tty(client))
      drain(tty)
      before_key()
      t0 = :erlang.monotonic_time(:nanosecond)
      Driver.type(client, ch)

      case await_cell(tty, {r.x + x, r.y + y}, [ch], deadline()) do
        :timeout -> :timeout
        at when at < t0 -> :invalid
        at -> (at - t0) / 1000
      end
    end

    defp clear(client, %{id: id, rect: r} = pane, at) do
      tty = Driver.tty(client)
      drain(tty)

      if Process.get({__MODULE__, :kernel}) == :real do
        Driver.type(client, "\r")
        until(fn -> elem(cursor(pane), 0) == 0 and cursor(pane) != at end, @key_timeout_ms)
        quiet(tty)
      else
        Driver.output(id, "\e[2J\e[1;1H")

        :timeout != await_cell(tty, {r.x, r.y}, ["", " "], deadline()) or
          Mix.raise("bench: clear")
      end
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

    # Attaches client B at @second_size and types into A's focused pane (B's view of it:
    # its own rect, cursor kept inside both rects), timing until B's cell shows the key.
    # B is stopped after, so A drives the size again; A then waits until quiet.
    defp second_client(client, pane, cfg) do
      b = start_client(@second_size)
      tty = Driver.tty(b)

      try do
        %{rect: rb} = Enum.find(Driver.scene(b).panes, &(&1.id == pane.id))
        view = %{tty: tty, rect: rb, w: min(rb.w, pane.rect.w), h: min(rb.h, pane.rect.h)}
        type_loop(client, pane, &(&1 >= div(@second_keys * cfg.keys, 1000)), :idle, view)
      after
        Supervisor.stop(b)
        drain(tty)
        :ok = Driver.quiesce(client)
      end
    end

    # -- frame cost ---------------------------------------------------------

    defp frame_cost(scene, cfg) do
      {cols, rows} = cfg.size
      {:ok, tty} = Tty.open(%{size: {cols, rows, 0, 0}})
      theme = Theme.default()
      theme = {theme, Chrome.layout(scene.chrome, scene.size, theme)}
      full = full_rows(scene, "x")
      alt = full_rows(scene, "y")
      [%{id: one} | _] = scene.panes

      blit = fn rows, repaint ->
        Blit.frame(tty, compose(cfg.compose, scene, rows, theme), %{
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

    # the scene with the rename prompt on top (pure: the Store's app is not changed)
    defp with_prompt(scene) do
      {app, []} = Prompt.rename_tab(Store.snapshot())
      modal = Modal.view(app, scene.size)
      %{scene | chrome: %{scene.chrome | children: scene.chrome.children ++ [modal]}}
    end

    # the chrome layout is computed once per chrome change in Render, so once here
    defp compose("raw", scene, rows, {theme, chrome}),
      do: Compose.frame(scene, rows, theme, chrome)

    defp compose("inline", scene, rows, tc), do: guarded(scene, rows, tc, [])
    defp compose("budget", scene, rows, tc), do: guarded(scene, rows, tc, budget_ms: 50)

    defp guarded(scene, rows, {theme, chrome}, opts) do
      args = [scene, rows, %{}, theme, chrome]
      {:ok, {frame, _}} = HerdrReload.Guard.run(Compose, :screen, args, [scan: false] ++ opts)
      frame
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
          Enum.map(flooded, fn %{id: id} ->
            Task.async(fn ->
              if cfg.file, do: cat(id, cfg.file), else: feed(id, chunk, chunks)
            end)
          end)

        stop? = &(&1 >= cfg.flood_min_keys and done?(feeders))
        typing = type_loop(client, typed, stop?, :paced)
        throttled = feeders |> Task.await_many(:infinity) |> Enum.sum()
        wall = System.monotonic_time(:millisecond) - t0

        %{
          panes: length(flooded),
          bytes_per_pane: if(cfg.file, do: File.stat!(cfg.file).size, else: chunks * @chunk),
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

    # real kernel: the pane's shell runs `cat file` (input written to its pty); done once
    # the marker line is on screen. Returns 0 (no throttling).
    defp cat(id, file) do
      {:ok, %{pty: pty}} = Kernel.keeper().lookup(Rows.kernel_id(id))
      until(fn -> text(id) =~ "$" end, 5000)
      :ok = Kernel.pty().write(pty, "cat #{file}\r")
      until(fn -> text(id) =~ @flood_end end, @flood_timeout_ms, "pane #{id}: cat did not finish")
      0
    end

    # Fake.Pty applies no backpressure; yield 1ms while its or the vt's mailbox is deep.
    defp feed(id, chunk, n) do
      {:ok, %{pty: pty, vt: vt}} = Keeper.lookup(Rows.kernel_id(id))

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
        {:monitor, who, kind, info} when kind in [:long_schedule, :long_gc] ->
          ev = {Keyword.get(info, :timeout, 0), info[:in], info[:out], who(who)}
          collect(Map.update!(acc, kind, &[ev | &1]))

        {:stop, from} ->
          send(from, {:stopped, self(), Map.new(acc, fn {k, ms} -> {k, events(ms)} end)})

        _ ->
          collect(acc)
      end
    end

    defp events(evs) do
      {max, at, out, who} = Enum.max_by(evs, &elem(&1, 0), fn -> {0, nil, nil, nil} end)
      %{count: length(evs), max_ms: max, max_in: inspect(at), max_out: inspect(out), max_who: who}
    end

    # the process's initial call (registered name if any), resolved when the event arrives
    defp who(pid) when is_pid(pid) do
      case Process.info(pid, [:registered_name, :dictionary]) do
        [registered_name: name, dictionary: _] when name != [] -> inspect(name)
        [registered_name: _, dictionary: d] -> inspect(d[:"$initial_call"])
        nil -> "dead"
      end
    end

    defp who(port), do: inspect(port)

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
        frame_15_dim_mean_us: r.frame_15_dim.repaint.mean,
        frame_ratio: ratio,
        stall_probe_max_ms: st.probe_max_ms,
        long_schedule_count: st.monitor.long_schedule.count,
        typing_during_flood_p95_us: st.typing.p95,
        quick: cfg.quick,
        kernel: cfg.kernel,
        keystroke_fast: r.fast,
        keystroke_slow: r.slow,
        keystroke_paced: r.paced,
        second_client: r.second,
        frame_1: f1,
        frame_15: f15,
        frame_15_dim: r.frame_15_dim,
        stall: st,
        environment: environment()
      }

      name =
        "bench/m3#{if cfg.kernel == :real, do: "-real"}#{size_suffix(cfg)}#{if cfg.quick, do: "-quick"}.json"

      path = Mix.Project.build_path() |> Path.dirname() |> Path.join(name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(json))
      Mix.shell().info(table(r, ratio, cfg))
      Mix.shell().info("\nwrote #{Path.relative_to_cwd(path)}")
    end

    defp size_suffix(%{size: @size}), do: ""
    defp size_suffix(%{size: {c, r}}), do: "-#{c}x#{r}"

    defp table(r, ratio, cfg) do
      %{frame_1: f1, frame_15: f15, stall: st} = r
      env = environment()
      {cols, rows} = cfg.size
      geo = "#{cols}x#{rows}"
      {bc, br} = @second_size

      """
      ## herdr-live M3 bench: #{title(cfg)}; targets judged at M6

      #{if cfg.quick, do: "**QUICK run (every metric 10x smaller)**\n", else: ""}
      | metric | value | target (design.md, judged at M6) |
      |---|---|---|
      | keystroke -> glass idle, fast path (n=#{r.fast.n}) | #{keys(r.fast)} | <= herdr + 1ms p95 |
      | keystroke -> glass idle, slow path (n=#{r.slow.n}) | #{keys(r.slow)} | <= herdr + 1ms p95 |
      | keystroke -> glass, 2ms after each frame, fast path (n=#{r.paced.n}) | #{keys(r.paced)} | reference |
      | second client: key in A -> visible in B (n=#{r.second.n}) | #{keys(r.second)} | reference |
      | frame cost #{geo}, 1 full pane (repaint) | #{frame(f1.repaint)} | |
      | frame cost #{geo}, #{f15.panes} full panes (repaint) | #{frame(f15.repaint)} | |
      | frame cost ratio #{f15.panes}/1 (mean) | #{fmt(ratio)}x | within 2x herdr's ratio |
      | frame cost #{geo}, #{f15.panes} panes, 1 pane dirty (full compose, no repaint) | #{frame(f15.dirty)} | reference |
      | frame cost #{geo}, #{f15.panes} full panes under a dimming modal (repaint) | #{frame(r.frame_15_dim.repaint)} | reference |
      | flood: #{st.panes} panes x #{div(st.bytes_per_pane, 1024 * 1024)}MiB, wall time | #{st.wall_ms} ms | |
      | flood: Process.sleep(1) probe max overshoot | #{fmt(st.probe_max_ms)} ms | no stall > 10ms |
      | flood: long_schedule >= 5ms events (max) | #{st.monitor.long_schedule.count} (#{st.monitor.long_schedule.max_ms} ms, #{st.monitor.long_schedule.max_who}, in #{st.monitor.long_schedule.max_in}, out #{st.monitor.long_schedule.max_out}) | |
      | flood: long_gc >= 5ms events (max) | #{st.monitor.long_gc.count} (#{st.monitor.long_gc.max_ms} ms) | |
      | flood: typing in a 16th pane (n=#{st.typing.n}) | #{keys(st.typing)} | <= 20ms |

      Method: keystroke t0 = monotonic time before `Fake.Tty.inject` of one printable char;
      t1 = `at` of the latest logged `Fake.Blit` frame when the target cell first shows it
      (read together; an upper bound), samples with t1 < t0 are counted invalid.
      One keystroke at a time, waiting for its frame. Idle rows then wait until no frame for
      min_frame_interval_ms + 2ms (each keystroke yields one frame: the cursor comes from
      the row cache with the rows), then 2ms; the "2ms after each frame" row and flood
      typing only sleep 2ms, so frame pacing can delay the next key's frame. Second client:
      client B (#{bc}x#{br}) attached to A's (#{geo}) session; keys are typed into A on the
      fast path, idle mode, timed until B's own cell for the pane cursor shows the char
      (cursor kept inside both rects; B detaches afterwards). Slow path = fast-path
      `:persistent_term` republished with `passthrough: false` (re-asserted before each key),
      so keys go client Input -> Client.Session -> App.Store. Client frames are paced at
      min_frame_interval_ms. Frame cost = `Compose.frame/4` + `Fake.Blit.frame/3`,
      #{cfg.warmup} warmup + #{cfg.iters} iterations, on a dedicated fake tty. #{String.trim_trailing(flood_method(cfg, st))}

      Environment: OTP #{env.otp}, Elixir #{env.elixir}, #{env.schedulers} schedulers, #{env.os}
      """
    end

    defp title(%{kernel: :real}),
      do: "real server kernel (HerdrServer.Native.*, /bin/sh panes), fake terminal client"

    defp title(_cfg), do: "against Kernel.Fake: Elixir side only"

    defp flood_method(%{kernel: :real}, _st) do
      """
      Real kernel: keys are typed at the pane's cursor (from the row cache); the typed pane
      runs `exec cat` (echo by the tty line discipline), enter when its row is full. Flood =
      each of 15 `/bin/sh` panes runs `cat` of one generated file of 64-byte lines (input
      written to its pty), done when the end marker is on its screen; the kernel's own
      damage coalescing and pty backpressure apply.
      """
    end

    defp flood_method(_cfg, st) do
      """
      Flood = 15
      feeder processes pushing 64KiB chunks of one binary via `Fake.Pty.output/2`; the fake
      applies no real backpressure, feeders sleep 1ms while pty+vt mailboxes exceed
      #{@mailbox_limit} (#{st.throttle_sleeps} sleeps); the fake vt keeps only the tail of each chunk.
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
