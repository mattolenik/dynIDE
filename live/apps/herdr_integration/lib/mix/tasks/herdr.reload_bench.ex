# Test-only, like `mix herdr.bench`: drives a client with HerdrIntegration.Driver
# (test/support). Outside MIX_ENV=test the task does not exist.
if Mix.env() == :test do
  defmodule Mix.Tasks.Herdr.ReloadBench do
    @shortdoc "Runs one M4 slice-1 reload metric (MIX_ENV=test)"
    @moduledoc """
    `mix herdr.reload_bench <scenario> [--iterations N] [--kernel fake|real]`, run with
    `MIX_ENV=test` from `live/`. Entry points: `live/bench/reload/<scenario>.sh`.

    Boots herdr_server and one terminal client on the fakes (`--kernel real` restarts
    herdr_server on `HerdrServer.Native.*` with `/bin/sh` panes, as `mix herdr.bench`),
    starts the reload pipeline (Notices, the real `HerdrReload.Server`, the Watcher)
    against the umbrella root, edits real sources and measures from `File.write` to the
    `{:loaded}` notice and to "visible": the first client frame (`Fake.Blit` screen)
    showing the edit's per-iteration marker. Every edited file is restored byte-for-byte
    in an `after` and its restoring reload awaited.

    Scenarios: #{Enum.join(~w(render view ui_field session_field scene_field view_loop closure pane_in_window cat15), ", ")}.

    Prints `RESULT scenario=... key=value ...` (one line) after the details. p95 is
    nearest rank, so with n=10 it is the max.

    Diagnostics: `HERDR_RELOAD_BENCH_TRACE=1` prints the reload pipeline's calls (watcher
    events, `Server.reload`, compile phases, `File.touch!`) in ms since each write;
    `HERDR_RELOAD_BENCH_IDLE=<ms>` idles that long after the scenario (before the restore).

    Notices: the info notice lifetime is set to #{150}ms and each iteration starts after
    #{400}ms without reload events, so every `{:loaded}` notice repaints (the default 3s
    notice would swallow repeated identical "reloaded N modules" repaints of edits less
    than 3s apart; a human editing slower than that sees the same repaint).
    """
    use Mix.Task

    alias HerdrIntegration.Driver
    alias HerdrReload.{LocalFuns, Notices, Server}
    alias HerdrServer.App.Store
    alias HerdrServer.Kernel
    alias HerdrServer.Kernel.Fake.{Keeper, Pty}
    alias HerdrServer.Pane.Rows
    alias HerdrTerm.Client
    alias HerdrTerm.Kernel.Fake.{Blit, Tty}

    @scenarios ~w(render view ui_field session_field scene_field view_loop closure pane_in_window cat15)
    @size {120, 40}
    @settle_ms 400
    @load_timeout 30_000
    @visible_timeout 5_000

    @view "apps/herdr_server/lib/herdr_server/view.ex"
    @status "apps/herdr_server/lib/herdr_server/view/status.ex"
    @tabs "apps/herdr_term/lib/herdr_term/client/term/render/chrome/tabs.ex"
    @ui "apps/herdr_server/lib/herdr_server/app/ui.ex"
    @session "apps/herdr_server/lib/herdr_server/app/session.ex"
    @node "apps/herdr_scene/lib/herdr_scene/scene/node.ex"
    @actions "apps/herdr_server/lib/herdr_server/app/actions.ex"

    # a list literal in View.Status whose nodes render on the status row
    @view_left "left = left ++ runtime"

    @impl Mix.Task
    def run(args) do
      {opts, argv, _} =
        OptionParser.parse(args, strict: [iterations: :integer, kernel: :string])

      scenario =
        case argv do
          [s] when s in @scenarios -> s
          _ -> Mix.raise("usage: mix herdr.reload_bench <#{Enum.join(@scenarios, "|")}>")
        end

      cfg = boot(scenario, opts)
      snapshot = beams()
      sup = start_reload()
      if System.get_env("HERDR_RELOAD_BENCH_TRACE"), do: trace()
      Driver.reset()
      client = start_client(@size)
      Process.put(:client, client)

      try do
        result = scenario(scenario, client, cfg)
        if t = System.get_env("HERDR_RELOAD_BENCH_IDLE"), do: idle(String.to_integer(t))
        report(scenario, cfg, result)
      after
        teardown(cfg, snapshot, sup)
      end
    end

    defp boot(scenario, opts) do
      Mix.Task.run("app.start")

      # app.start recompiled this task: this process runs its old code, which would block
      # every reload's purge (the reload server refuses the batch)
      if :erlang.check_old_code(__MODULE__),
        do: Mix.raise("bench: task just recompiled; run `MIX_ENV=test mix compile` first")

      Logger.configure(level: :warning)
      Application.put_env(:herdr_server, :notice_ms, info: 150, warning: 8000)
      kernel = if opts[:kernel] == "real" or scenario == "cat15", do: :real, else: :fake
      if kernel == :real, do: real_kernel()
      Process.put(:originals, %{})

      %{
        n: Keyword.get(opts, :iterations, 10),
        kernel: kernel,
        root: Path.dirname(Mix.Project.deps_path())
      }
    end

    defp teardown(cfg, snapshot, sup) do
      # nothing renders or acts during the restoring reloads
      stop_feeders()
      Supervisor.stop(Process.get(:client))
      Driver.reset()
      seen = length(events())
      restore_all(cfg.root)
      check_build(snapshot)

      for ev <- Enum.drop(events(), seen), not match?({:loaded, _, _}, ev) do
        text = inspect(ev, limit: 8, printable_limit: 200) |> String.slice(0, 400)
        IO.puts(:stderr, "restore event: #{text}")
      end

      # Registry.register linked us to the notices registry: its shutdown is not ours
      Registry.unregister(Notices, :events)
      Process.exit(Process.get(:event_log), :kill)
      Supervisor.stop(sup)
      for f <- Process.get(:tmp_files, []), do: File.rm(f)
    end

    # -- setup ----------------------------------------------------------------

    # HerdrReload.Supervisor (Notices, the real Server, the Watcher on apps/*/lib): the
    # task runs with the umbrella as the current Mix project, the Server's default.
    # Config `enabled` is false in test, so nothing else started it.
    defp start_reload do
      {:ok, sup} = HerdrReload.Supervisor.start_link()
      Notices.subscribe()
      me = self()
      Process.put(:event_log, spawn(fn -> event_log(me) end))
      # fsevents warm-up, and ReloadNotices retries its subscription every 500ms
      Process.sleep(1000)
      sup
    end

    defp real_kernel do
      :ok = Application.stop(:herdr_server)
      native = [vt: HerdrServer.Native.Vt, pty: HerdrServer.Native.Pty]
      Application.put_env(:herdr_server, :kernel, native ++ [keeper: HerdrServer.Native.Keeper])
      System.put_env("SHELL", "/bin/sh")

      Application.put_env(:herdr_server, :pane_env, [
        {"PS1", "$ "},
        {"BASH_SILENCE_DEPRECATION_WARNING", "1"}
      ])

      {:ok, _} = Application.ensure_all_started(:herdr_server)
    end

    defp start_client({cols, rows}) do
      {:ok, sup} = Client.start_link(id: make_ref(), tty_opts: %{size: {cols, rows, 0, 0}})

      until(
        fn -> Driver.scene(sup) != nil and Blit.frames(Driver.tty(sup)) != [] end,
        5000,
        "client did not come up"
      )

      :ok = Driver.quiesce(sup)
      sup
    end

    # -- scenarios ------------------------------------------------------------

    defp scenario("render", client, cfg) do
      # the tab label line of the tab bar rasterizer; the marker lands in every tab
      old = ~S[<> to_string(name || "")]

      edit_loop(
        client,
        cfg,
        @tabs,
        fn i -> {old, old <> ~s| <> "rmk#{i}z"|} end,
        &"rmk#{&1}z"
      )
    end

    defp scenario("view", client, cfg), do: view_edit(client, cfg)

    defp scenario("cat15", client, cfg) do
      file = cat_file(8 * 1024 * 1024)
      panes = Driver.grow(client, 15).panes
      Enum.each(panes, &cat_loop(&1.id, file))
      # output is flowing in every pane
      until(fn -> Enum.all?(panes, &(text(&1.id) =~ "cat15-line")) end, 10_000, "cat not flowing")
      Map.put(view_edit(client, cfg), :extra, "panes=#{length(panes)} kernel=real")
    end

    defp scenario("ui_field", client, cfg) do
      panes = Driver.grow(client, 15).panes
      Enum.each(panes, &start_feeder(&1.id))
      # the whole (formatted, multi-line) defstruct of App.Ui; fields go after the last one
      ui_old = Regex.run(~r/  defstruct \[\n.*?\n  \]\n/s, File.read!(Path.join(cfg.root, @ui)))
      ui_old = if ui_old, do: hd(ui_old), else: Mix.raise("bench: no App.Ui defstruct block")

      ui = fn i ->
        {ui_old,
         String.replace_suffix(
           ui_old,
           "\n  ]\n",
           ~s|,\n    marker: "umk#{i}z",\n    bench_#{i}: nil\n  ]\n|
         )}
      end

      # View renders the marker read from the new struct's default: app state built
      # before the reload has no :marker key, so the default is what is shown
      view =
        {@view_left,
         @view_left <>
           " ++ [text(:bench, %HerdrServer.App.Ui{}.marker, :muted)]"}

      warm = setup_edit(client, cfg, [{@status, [view]}, {@ui, [ui.(100)]}], "umk100z")
      r = edit_loop(client, cfg, @ui, ui, &"umk#{&1}z")

      Map.merge(r, %{
        warmup: warm,
        extra: "panes=#{length(panes)} streaming=fake_100KiB/s_per_pane"
      })
    end

    defp scenario("session_field", client, cfg) do
      old = "area: %{x: 26, y: 1, w: 54, h: 22}\n"

      r =
        edit_loop(
          client,
          cfg,
          @session,
          fn i -> {old, String.trim_trailing(old) <> ",\n            bench_#{i}: nil\n"} end,
          nil
        )

      Map.put(r, :extra, "alive=#{alive_check(client)}")
    end

    defp scenario("scene_field", client, cfg) do
      old = "defstruct [:role, :id, :rect, :text, :token, props: %{}, children: []]"

      r =
        edit_loop(
          client,
          cfg,
          @node,
          fn i -> {old, String.replace_suffix(old, "]", ", bench_#{i}: nil]")} end,
          nil
        )

      Map.put(r, :extra, "alive=#{alive_check(client)}")
    end

    defp scenario("view_loop", client, cfg), do: view_loop(client, cfg)
    defp scenario("closure", client, cfg), do: closure(client, cfg)
    defp scenario("pane_in_window", client, cfg), do: pane_in_window(client, cfg)

    defp view_edit(client, cfg) do
      edit_loop(
        client,
        cfg,
        @status,
        fn i ->
          {@view_left, @view_left <> ~s| ++ [text(:bench, "vmk#{i}z", :muted)]|}
        end,
        &"vmk#{&1}z"
      )
    end

    # -- the save -> loaded / visible loop --------------------------------------

    # One warm-up edit (i = 0, reported apart: the VM's first compile also loads Mix's
    # manifests), then n measured ones. `change.(i)` gives {old, new} for the original
    # source; `marker.(i)` (or nil) the text that must appear on the client's screen.
    defp edit_loop(client, cfg, rel, change, marker) do
      warm = measure_edit(client, cfg, rel, change, marker, 0)
      samples = for i <- 1..cfg.n, do: measure_edit(client, cfg, rel, change, marker, i)
      %{warmup: warm, samples: samples}
    end

    defp measure_edit(client, cfg, rel, change, marker, i) do
      settle()
      src = edited(cfg.root, rel, [change.(i)])
      path = Path.join(cfg.root, rel)
      t0 = now()

      if System.get_env("HERDR_RELOAD_BENCH_TRACE"),
        do: :ets.insert(:bench_t0, {:t0, System.monotonic_time(:microsecond)})

      if System.get_env("HERDR_RELOAD_BENCH_TRACE"), do: IO.puts("TRACE write #{i}")
      File.write!(path, src)
      mods = await_loaded()
      loaded = ms(t0)
      visible = if marker, do: visible(client, marker.(i), t0)
      %{loaded: loaded, visible: visible, mods: mods}
    end

    # several files written at once (one watcher batch), measured like one edit
    defp setup_edit(client, cfg, files, marker) do
      settle()

      srcs =
        for {rel, changes} <- files,
            do: {Path.join(cfg.root, rel), edited(cfg.root, rel, changes)}

      t0 = now()
      for {p, s} <- srcs, do: File.write!(p, s)
      mods = await_loaded()
      %{loaded: ms(t0), visible: visible(client, marker, t0), mods: mods}
    end

    defp visible(client, marker, t0) do
      ok? =
        Driver.wait_screen(client, &Enum.any?(&1, fn row -> row =~ marker end), @visible_timeout)

      if ok?,
        do: ms(t0),
        else: Mix.raise("bench: #{marker} not visible within #{@visible_timeout}ms")
    end

    # -- view_loop ------------------------------------------------------------

    # View.compute spins forever at 97 columns. Resize the client there: the Session's
    # guarded View.compute (budget 50ms) times out, the Server rolls the batch back, the
    # re-run on the old code computes the 97-column scene. Measured: resize -> client
    # scene at 97 columns, and -> a frame 97 cells wide.
    defp view_loop(client, cfg) do
      head =
        "def compute(app, %State{size: %{cols: cols, rows: rows} = size} = client) do\n"

      pane =
        "  defp pane(%{id: id, rect: rect, border: border}, app, %State{transport: transport} = client) do\n"

      {cols, rows} = @size

      samples =
        for i <- 0..cfg.n do
          settle()

          spin = [
            {head, head <> "    if cols == 97, do: bench_spin(#{i})\n"},
            {pane, "  defp bench_spin(n), do: bench_spin(n)\n\n" <> pane}
          ]

          File.write!(Path.join(cfg.root, @view), edited(cfg.root, @view, spin))
          _ = await_loaded()
          drain_notices()
          tty = Driver.tty(client)
          t0 = now()
          resize(client, 97, rows)

          until_frame(
            client,
            fn -> Driver.scene(client).size.cols == 97 end,
            2000,
            "no 97-col scene"
          )

          scene_ms = ms(t0)
          until_frame(client, fn -> width(tty) == 97 end, 2000, "no 97-col frame")
          frame_ms = ms(t0)
          rolled = await_event(&match?({:rolled_back, _, _, _}, &1), 2000)
          if rolled == nil, do: Mix.raise("bench: no {:rolled_back} notice")
          {:rolled_back, _, _, reason} = rolled
          final = Driver.scene(client).size.cols
          if final != 97, do: Mix.raise("bench: dropped resize, scene is #{final} cols")
          resize(client, cols, rows)

          until_frame(
            client,
            fn -> Driver.scene(client).size.cols == cols end,
            2000,
            "no resize back"
          )

          %{loaded: scene_ms, visible: frame_ms, mods: [], reason: summary(reason), i: i}
        end

      restore_all(cfg.root)
      [warm | rest] = samples

      %{
        warmup: warm,
        samples: rest,
        extra: "budget_ms=50 reason=#{hd(rest).reason} final_cols=97"
      }
    end

    defp resize(client, cols, rows) do
      Tty.set_size(Driver.tty(client), {cols, rows, 0, 0})
      send(Client.owner(client), :sigwinch)
    end

    defp width(tty) do
      case Blit.screen(tty) do
        [row | _] -> String.length(row)
        _ -> 0
      end
    end

    # -- closure --------------------------------------------------------------

    @paste_clause "  def apply(app, {:paste, bin}), do: to_focused(app, :paste, bin)\n"

    # App.Actions stores a local fun in app.ui.status on a "bench-closure" paste. The
    # guarded Actions.apply scans its result: {:rejected} notice, the batch rolls back, the
    # paste re-runs on the old code (goes to the pane). Then a second edit of the same
    # module reloads (purging the old code): nothing may be killed.
    defp closure(client, cfg) do
      Driver.grow(client, 2)
      store = Process.whereis(Store)
      panes = pane_servers()

      samples =
        for i <- 0..cfg.n do
          settle()

          clause =
            "  def apply(app, {:paste, \"bench-closure\"}),\n    do: {put_in(app.ui.status, Map.put(app.ui.status, :bench, fn -> #{i} end)), []}\n\n"

          File.write!(
            Path.join(cfg.root, @actions),
            edited(cfg.root, @actions, [{@paste_clause, clause <> @paste_clause}])
          )

          _ = await_loaded()
          drain_notices()
          t0 = now()
          Driver.type(client, "\e[200~bench-closure\e[201~")

          rejected =
            await_event(&match?({:rejected, _, _}, &1), 2000) ||
              Mix.raise("bench: no {:rejected} notice")

          rejected_ms = ms(t0)

          _ =
            await_event(&match?({:rolled_back, _, _, _}, &1), 2000) ||
              Mix.raise("bench: no {:rolled_back}")

          # second reload of App.Actions: purges the code generation the fun would pin
          settle()
          second = "  def bench_second, do: #{i}\n\n" <> @paste_clause

          File.write!(
            Path.join(cfg.root, @actions),
            edited(cfg.root, @actions, [{@paste_clause, second}])
          )

          _ = await_loaded()
          Process.sleep(50)
          blocked = await_event(&match?({:purge_blocked, _, _}, &1), 0)
          app = Store.snapshot()

          checks = [
            store_pid: Process.whereis(Store) == store,
            pane_pids: pane_servers() == panes,
            no_purge_blocked: blocked == nil,
            no_fun_in_state: LocalFuns.find(app) == :ok
          ]

          for {k, ok} <- checks, !ok, do: Mix.raise("bench: closure check #{k} failed")
          {:rejected, mod, path} = rejected

          %{
            loaded: rejected_ms,
            visible: nil,
            mods: [],
            i: i,
            notice: "#{inspect(mod)} at #{inspect(path)}"
          }
        end

      restore_all(cfg.root)
      [warm | rest] = samples

      %{
        warmup: warm,
        samples: rest,
        extra:
          "store_pid_unchanged=true pane_pids_unchanged=true purge_blocked=0 rejected=#{hd(rest).notice |> String.replace(" ", "")}"
      }
    end

    defp pane_servers do
      Registry.select(HerdrServer.Pane.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.sort()
    end

    # -- pane_in_window -------------------------------------------------------

    # Batch K's App.Actions sets session.next_id to :corrupt on a "bench-corrupt" paste
    # (only Actions reads next_id, so the Store, View and fast path keep working). The
    # next split (prefix v, a Store.run of Actions.split) raises in `+` on the new code,
    # the Guard rolls K back, and the old code raises on the same state too: a repeat
    # failure.
    # The Store restores K's state_at_load (from before the split) and reconciles with the
    # keeper: the pane split off after K's load must be adopted into a "scratch" tab.
    defp pane_in_window(client, cfg) do
      clause = fn i ->
        "  def apply(app, {:paste, \"bench-corrupt\"}),\n    do: {put_in(app.session.next_id, {:corrupt, #{i}}), []}\n\n"
      end

      samples =
        for i <- 0..cfg.n do
          client = if i == 0, do: client, else: fresh_client(Process.get(:client))
          Driver.grow(client, 2)
          # the Store's mirror flush is debounced 20ms: state_at_load must see 2 panes
          Process.sleep(100)
          settle()

          File.write!(
            Path.join(cfg.root, @actions),
            edited(cfg.root, @actions, [{@paste_clause, clause.(i) <> @paste_clause}])
          )

          _ = await_loaded()
          drain_notices()
          before = MapSet.new(Driver.scene(client).panes, & &1.id)
          Driver.type(client, "\x02v")
          until_frame(client, fn -> length(Driver.scene(client).panes) == 3 end, 2000, "no split")

          [spawned] =
            Driver.scene(client).panes |> Enum.map(& &1.id) |> Enum.reject(&(&1 in before))

          Driver.type(client, "\e[200~bench-corrupt\e[201~")

          until(
            fn -> match?({:corrupt, _}, Store.snapshot().session.next_id) end,
            2000,
            "no corrupt state"
          )

          t0 = now()
          Driver.type(client, "\x02v")

          until_frame(
            client,
            fn -> "scratch" in tab_names(Driver.scene(client)) end,
            3000,
            fn -> "iteration #{i}: no scratch tab; #{diagnose(client)}" end
          )

          restored_ms = ms(t0)

          ok? =
            Driver.wait_screen(client, &Enum.any?(&1, fn r -> r =~ "state restored" end), 2000)

          rolled = await_event(&match?({:rolled_back, _, _, _}, &1), 1000)
          checks = reconciled(spawned) ++ [restored_notice: ok?, rolled_back: rolled != nil]
          for {k, ok} <- checks, !ok, do: Mix.raise("bench: pane_in_window check #{k} failed")
          restore_all(cfg.root)
          %{loaded: restored_ms, visible: nil, mods: [], i: i}
        end

      [warm | rest] = samples

      %{
        warmup: warm,
        samples: rest,
        extra:
          "adopted_in_scratch=true keeper_all_mapped=true no_orphan_servers=true restored_notice=true"
      }
    end

    defp fresh_client(client) do
      Supervisor.stop(client)
      Driver.reset()
      client = start_client(@size)
      Process.put(:client, client)
      client
    end

    defp tab_names(scene) do
      case HerdrScene.Scene.Node.find(scene.chrome, [:tabs]) do
        nil -> []
        tabs -> for %{role: :tab, text: t} <- tabs.children, do: t
      end
    end

    defp reconciled(spawned) do
      app = Store.snapshot()
      ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
      scratch = Enum.find(ws.tabs, &(&1.name == "scratch"))
      in_app = MapSet.new(Map.keys(app.session.panes))
      mapped = for {id, kid} <- Rows.kernel_ids(), id in in_app, into: MapSet.new(), do: kid

      [
        adopted:
          scratch != nil and spawned in HerdrServer.Layout.pane_ids(scratch.layout) and
            spawned in in_app,
        keeper_all_mapped: Enum.all?(Kernel.keeper().ids(), &(&1 in mapped)),
        no_orphan_servers: Enum.all?(pane_servers(), fn {id, _} -> id in in_app end),
        servers_for_all:
          Enum.all?(in_app, fn id -> Registry.lookup(HerdrServer.Pane.Registry, id) != [] end)
      ]
    end

    # -- load (fake streaming, real cat) ----------------------------------------

    # Fake.Pty applies no backpressure: 1KiB every 10ms per pane (~100KiB/s, a busy log
    # tail), skipped while the pty's or vt's mailbox is deep (as mix herdr.bench does)
    defp start_feeder(id) do
      {:ok, %{pty: pty, vt: vt}} = Keeper.lookup(Rows.kernel_id(id))
      line = "feed #{id} " <> String.duplicate("0123456789abcdef", 4) <> "\r\n"
      chunk = :binary.copy(line, div(1024, byte_size(line)))
      pid = spawn(fn -> feed(pty, vt, chunk) end)
      Process.put(:feeders, [pid | Process.get(:feeders, [])])
    end

    defp feed(pty, vt, chunk) do
      if qlen(pty) + qlen(vt) < 50, do: Pty.output(pty, chunk)
      Process.sleep(10)
      feed(pty, vt, chunk)
    end

    defp qlen(pid) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> n
        nil -> 0
      end
    end

    defp stop_feeders, do: for(p <- Process.get(:feeders, []), do: Process.exit(p, :kill))

    defp cat_file(bytes) do
      path =
        Path.join(System.tmp_dir!(), "herdr-reload-cat-#{System.unique_integer([:positive])}")

      line = fn n -> String.pad_trailing("cat15-line #{n}", 62, ".") <> "\r\n" end
      File.write!(path, Enum.map(1..div(bytes, 64)//1, line))
      Process.put(:tmp_files, [path | Process.get(:tmp_files, [])])
      path
    end

    # the pane's shell cats the file in a loop until Driver.reset closes the pane
    defp cat_loop(id, file) do
      {:ok, %{pty: pty}} = Kernel.keeper().lookup(Rows.kernel_id(id))
      until(fn -> text(id) =~ "$" end, 5000, "pane #{id}: no prompt")
      :ok = Kernel.pty().write(pty, "while :; do cat #{file}; done\r")
    end

    defp text(id) do
      {:ok, %{vt: vt}} = Kernel.keeper().lookup(Rows.kernel_id(id))
      Kernel.vt().read_text(vt, :viewport)
    end

    # the app still answers and the client still draws after the struct reloads
    defp alive_check(client) do
      Driver.type(client, "\x02v")
      ok? = Driver.wait_screen(client, fn _ -> length(Driver.scene(client).panes) >= 2 end, 2000)
      ok? or Mix.raise("bench: app did not split after the reloads")
    end

    # -- sources --------------------------------------------------------------

    # the original source (read once per path) with every {old, new} applied; each old
    # must occur exactly once
    defp edited(root, rel, changes) do
      orig = original(root, rel)

      Enum.reduce(changes, orig, fn {old, new}, src ->
        case :binary.matches(src, old) do
          [_] -> String.replace(src, old, new)
          m -> Mix.raise("bench: #{length(m)} matches of #{inspect(old)} in #{rel}")
        end
      end)
    end

    defp original(root, rel) do
      origs = Process.get(:originals)

      case origs do
        %{^rel => src} ->
          src

        _ ->
          src = File.read!(Path.join(root, rel))
          Process.put(:originals, Map.put(origs, rel, src))
          src
      end
    end

    # Writes every changed original back and reloads them synchronously (the watcher's
    # batch for the same write is then a noop, or this one is). A restore whose code
    # equals what is loaded (a rolled-back edit) is a noop and sends no notice.
    defp restore_all(root) do
      dirty =
        for {rel, src} <- Process.get(:originals),
            path = Path.join(root, rel),
            File.read!(path) != src do
          File.write!(path, src)
          path
        end

      if dirty != [] do
        case Server.reload(dirty) do
          {:ok, _} -> :ok
          :noop -> :ok
          other -> IO.puts(:stderr, "restore reload: #{inspect(other)}")
        end

        settle()
      end
    end

    defp idle(ms) do
      IO.puts("TRACE idle start")
      if :ets.whereis(:bench_t0) != :undefined, do: :ets.insert(:bench_t0, {:t0, now()})
      Process.sleep(ms)
      IO.puts("TRACE idle end")
    end

    # Diagnostics: prints the reload pipeline's calls (watcher events, Server.reload,
    # compile phases, File.touch!) in ms since the latest edit's write
    defp trace do
      :ets.new(:bench_t0, [:named_table, :public])
      :ets.insert(:bench_t0, {:t0, System.monotonic_time(:microsecond)})
      tracer = spawn(fn -> tloop() end)
      ms = [{:_, [], [{:return_trace}]}]

      for {m, f} <- [
            {HerdrReload.Watcher, :handle_info},
            {HerdrReload.Server, :reload},
            {HerdrReload.Compiler, :pre_sweep},
            {HerdrReload.Compiler, :mix_compile},
            {HerdrReload.Compiler, :diff},
            {HerdrReload.Compiler, :disk_state},
            {HerdrReload.Server, :load_all},
            {HerdrReload.Server, :state_at_load},
            {HerdrReload.Compiler, :restore},
            {File, :touch!}
          ],
          do: :erlang.trace_pattern({m, f, :_}, ms, [:local])

      :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    end

    defp tloop do
      receive do
        msg ->
          t0 = :ets.lookup_element(:bench_t0, :t0, 2)
          dt = Float.round((System.monotonic_time(:microsecond) - t0) / 1000, 1)

          case msg do
            {:trace, _, :call, {m, f, a}} ->
              IO.puts(
                "TRACE #{dt} call #{inspect(m)}.#{f}/#{length(a)} #{if f == :handle_info, do: inspect(hd(a), limit: 3) |> String.slice(0, 100)}"
              )

            {:trace, _, :return_from, {m, f, n}, r} ->
              IO.puts(
                "TRACE #{dt} ret #{inspect(m)}.#{f}/#{n} #{inspect(r, limit: 3) |> String.slice(0, 80)}"
              )

            _ ->
              :ok
          end
      end

      tloop()
    end

    # -- build check ------------------------------------------------------------

    defp beams do
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin/*.beam")
      |> Path.wildcard()
      |> Map.new(&{&1, md5(&1)})
    end

    # Sources are restored byte-for-byte, so every beam on disk must hold the code the
    # run started with. A rollback of a batch compiled from the current source leaves the
    # previous (edited) beam on disk under an unchanged source digest, which Mix never
    # recompiles: such a source is written with an extra newline and back (two reloads),
    # then checked again.
    defp check_build(snapshot, tries \\ 2) do
      case for({p, bin} <- beams(), Map.get(snapshot, p) != bin, do: p) ++
             for(p <- Map.keys(snapshot), not File.exists?(p), do: p) do
        [] ->
          IO.puts("build check: ok, #{map_size(snapshot)} beams hold the run's starting code")

        bad when tries > 0 ->
          IO.puts(
            :stderr,
            "build check: #{length(bad)} beams differ, recompiling: #{inspect(Enum.map(bad, &Path.basename/1))}"
          )

          srcs = bad |> Enum.filter(&File.exists?/1) |> Enum.map(&source/1) |> Enum.uniq()

          for src <- srcs do
            orig = File.read!(src)
            File.write!(src, orig <> "\n")
            Server.reload([src])
            File.write!(src, orig)
            Server.reload([src])
          end

          settle()
          check_build(snapshot, tries - 1)

        bad ->
          Mix.raise(
            "bench: build left dirty (run `MIX_ENV=test mix compile --force`): #{inspect(bad)}"
          )
      end
    end

    # the code chunks only: the ExCk (type checker) chunk varies with compile order
    defp md5(path) do
      {:ok, {_, md5}} = :beam_lib.md5(String.to_charlist(path))
      md5
    end

    defp source(path) do
      {:ok, {_, [compile_info: info]}} =
        :beam_lib.chunks(String.to_charlist(path), [:compile_info])

      List.to_string(info[:source])
    end

    # -- notices and waiting ----------------------------------------------------

    # every reload event of the run, for the report (the bench's own receives consume
    # theirs from its mailbox)
    defp event_log(owner) do
      :ok = Notices.subscribe()
      event_log(owner, [])
    end

    defp event_log(owner, acc) do
      receive do
        {:herdr_reload, ev} ->
          event_log(owner, [ev | acc])

        {:dump, ^owner} ->
          send(owner, {:event_log, Enum.reverse(acc)})
          event_log(owner, acc)
      end
    end

    defp events do
      send(Process.get(:event_log), {:dump, self()})

      receive do
        {:event_log, evs} -> evs
      after
        2000 -> []
      end
    end

    defp await_loaded do
      receive do
        {:herdr_reload, {:loaded, _, mods}} -> mods
        {:herdr_reload, {:compile_error, d}} -> Mix.raise("bench: compile error #{inspect(d)}")
      after
        @load_timeout ->
          Mix.raise(
            "bench: no {:loaded} notice in #{@load_timeout}ms; events: #{inspect(events(), limit: 20) |> String.slice(0, 1500)}"
          )
      end
    end

    defp await_event(match?, timeout) do
      receive do
        {:herdr_reload, ev} -> if match?.(ev), do: ev, else: await_event(match?, timeout)
      after
        timeout -> nil
      end
    end

    defp drain_notices do
      receive do
        {:herdr_reload, _} -> drain_notices()
      after
        0 -> :ok
      end
    end

    # no reload event for @settle_ms (a late event of the previous edit is not counted)
    # and the client's frame messages drained
    defp settle do
      receive do
        {:herdr_reload, _} -> settle()
      after
        @settle_ms -> drain_frames()
      end
    end

    defp drain_frames do
      receive do
        {:frame, _, _} -> drain_frames()
      after
        0 -> :ok
      end
    end

    defp until_frame(client, check, timeout, what) do
      Driver.wait_screen(client, fn _ -> check.() end, timeout) or
        Mix.raise("bench: #{if is_function(what), do: what.(), else: what}")
    end

    defp diagnose(client) do
      app = Store.snapshot()
      ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
      tabs = Enum.map(ws.tabs, &{&1.name, HerdrServer.Layout.pane_ids(&1.layout)})
      evs = events() |> Enum.take(-4) |> inspect(limit: 6, printable_limit: 120)

      "scene tabs #{inspect(tab_names(Driver.scene(client)))}, store tabs #{inspect(tabs)}, " <>
        "next_id #{inspect(app.session.next_id)}, kernel ids #{inspect(Rows.kernel_ids())}, " <>
        "last events #{String.slice(evs, 0, 800)}"
    end

    defp until(check, left, what) do
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

    defp now, do: System.monotonic_time(:microsecond)
    defp ms(t0), do: Float.round((now() - t0) / 1000, 1)

    defp summary({:timeout, ms, _}), do: "timeout_#{ms}ms"
    defp summary({kind, _, _}), do: Atom.to_string(kind)
    defp summary(other), do: inspect(other)

    # -- report ---------------------------------------------------------------

    defp report(scenario, cfg, r) do
      loaded = Enum.map(r.samples, & &1.loaded)
      visible = r.samples |> Enum.map(& &1.visible) |> Enum.reject(&is_nil/1)
      fanout = r.samples |> Enum.map(&length(&1.mods)) |> Enum.uniq()
      {lk, vk} = labels(scenario)

      IO.puts("""
      == reload bench: #{scenario} (#{cfg.kernel} kernel, n=#{cfg.n}) ==
      #{lk} per iteration (ms): #{inspect(loaded)}
      #{if visible != [], do: "#{vk} per iteration (ms): #{inspect(visible)}\n", else: ""}warm-up (i=0, not counted): #{inspect(Map.take(r.warmup, [:loaded, :visible]))}
      fan-out per iteration: #{inspect(Enum.map(r.samples, &length(&1.mods)))}
      #{apps_line(r.samples)}p95 is nearest rank: with n=#{cfg.n} it is the #{if cfg.n < 20, do: "max", else: "p95"}
      """)

      parts =
        ["RESULT scenario=#{scenario}", "n=#{cfg.n}", "kernel=#{cfg.kernel}"] ++
          stats(lk, loaded) ++
          if(visible != [], do: stats(vk, visible), else: []) ++
          if(fanout != [0], do: ["fanout=#{Enum.join(fanout, ",")}"], else: []) ++
          List.wrap(r[:extra])

      evs = events()

      counts =
        evs
        |> Enum.frequencies_by(&elem(&1, 0))
        |> Enum.map_join(",", fn {k, v} -> "#{k}:#{v}" end)

      odd = Enum.reject(evs, &match?({:loaded, _, _}, &1))

      for ev <- odd,
          do:
            IO.puts(
              "  event: #{inspect(ev, limit: 8, printable_limit: 200) |> String.slice(0, 300)}"
            )

      IO.puts(Enum.join(parts ++ ["events=#{counts}"], " "))
    end

    defp labels("view_loop"), do: {"resize_to_scene", "resize_to_frame"}
    defp labels("closure"), do: {"event_to_rejected", nil}
    defp labels("pane_in_window"), do: {"event_to_restored", nil}
    defp labels(_), do: {"save_to_loaded", "save_to_visible"}

    defp apps_line(samples) do
      mods = samples |> Enum.flat_map(& &1.mods) |> Enum.uniq()

      if mods == [] do
        ""
      else
        by_app =
          mods
          |> Enum.group_by(&app_of/1)
          |> Enum.map_join(", ", fn {app, ms} -> "#{app}: #{length(ms)}" end)

        "modules by app (union): #{by_app}\n  #{inspect(Enum.sort(mods))}\n"
      end
    end

    defp app_of(mod) do
      case :application.get_application(mod) do
        {:ok, app} -> app
        :undefined -> :unknown
      end
    end

    defp stats(label, xs) do
      s = Enum.sort(xs)
      n = length(s)

      med =
        if rem(n, 2) == 1,
          do: Enum.at(s, div(n, 2)),
          else: (Enum.at(s, div(n, 2) - 1) + Enum.at(s, div(n, 2))) / 2

      [
        "#{label}_min_ms=#{fmt(hd(s))}",
        "#{label}_median_ms=#{fmt(med)}",
        "#{label}_p95_ms=#{fmt(Enum.at(s, max(ceil(0.95 * n) - 1, 0)))}",
        "#{label}_max_ms=#{fmt(List.last(s))}"
      ]
    end

    defp fmt(v), do: :erlang.float_to_binary(v / 1, decimals: 1)
  end
end
