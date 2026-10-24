defmodule HerdrReload.GuardTest do
  use HerdrReload.ReloadCase, async: false

  import ExUnit.CaptureLog

  alias HerdrReload.{Batch, Compiler, Guard, Notices, Server}

  defmodule Fixture do
    @moduledoc false
    def f(:ok), do: :fine
    def f(:boom), do: raise("boom")
    def f(:throw), do: throw(:t)
    def f(:exit), do: exit(:x)
    def f(:nested_exit), do: exit({:inner, [{Elixir.Nested.Mod, :g, 1, []}]})
    def f(:fun), do: %{cb: fn -> 1 end}
    def f(:loop), do: loop()

    def f({:count_boom, calls}) do
      :counters.add(calls, 1, 1)
      raise "boom"
    end

    def f({:report, to}) do
      send(to, {:worker, self()})
      loop()
    end

    defp loop, do: loop()
  end

  @mods [Toy.A, Toy.B]

  setup do
    on_exit(fn ->
      for m <- @mods do
        :code.purge(m)
        :code.delete(m)
        :code.purge(m)
      end
    end)
  end

  # no process and no table under this name: no counters, no attribution
  @nosrv [server: :guard_test_no_server]

  defp a_src(n),
    do:
      "defmodule Toy.A do\n  def f(:ok), do: #{n}\n  def f(:boom), do: raise(\"boom #{n}\")\nend\n"

  defp b_src(n), do: "defmodule Toy.B do\n  def g, do: #{n}\nend\n"
  defp path(dir, f), do: Path.join(dir, "lib/#{f}.ex")

  # starts a server on a toy project with `files` and loads them as batch 1
  defp toy!(app, files, server_opts \\ []) do
    dir = HerdrReload.ReloadCase.toy_project!(app, files)
    opts = [project_dir: dir, app: app]

    on_exit(fn ->
      for d <- Map.values(Compiler.ebin_dirs(opts)), do: :code.del_path(String.to_charlist(d))
    end)

    start_supervised!({Server, opts ++ server_opts})
    paths = files |> Map.keys() |> Enum.map(&Path.join(dir, &1))
    assert {:ok, %Batch{id: 1}} = Server.reload(paths)
    dir
  end

  test "each failure class returns its tag" do
    assert Guard.run(Fixture, :f, [:ok], @nosrv) == {:ok, :fine}

    assert {:failed, {:raise, %RuntimeError{message: "boom"}, [_ | _]}} =
             Guard.run(Fixture, :f, [:boom], @nosrv)

    assert {:failed, {:throw, :t, [_ | _]}} = Guard.run(Fixture, :f, [:throw], @nosrv)
    assert {:failed, {:exit, :x, [_ | _]}} = Guard.run(Fixture, :f, [:exit], @nosrv)
  end

  test "budget mode returns the same outcomes from a worker" do
    opts = [budget_ms: 1_000] ++ @nosrv
    assert Guard.run(Fixture, :f, [:ok], opts) == {:ok, :fine}
    assert {:failed, {:raise, %RuntimeError{}, _}} = Guard.run(Fixture, :f, [:boom], opts)
    assert {:failed, {:exit, :x, _}} = Guard.run(Fixture, :f, [:exit], opts)
    assert Process.info(self(), :links) == {:links, []}
    refute_received _
  end

  test "an infinite loop times out, reports its stack and the worker dies" do
    t0 = System.monotonic_time(:millisecond)

    assert {:failed, {:timeout, 50, stack}} =
             Guard.run(Fixture, :f, [:loop], [budget_ms: 50] ++ @nosrv)

    assert System.monotonic_time(:millisecond) - t0 < 200
    assert Enum.any?(stack, &match?({Fixture, :loop, 0, _}, &1))
    assert Process.info(self(), :links) == {:links, []}
    refute_received _
  end

  test "success bumps counters in the table named after the server" do
    :ets.new(:guard_test_ctr, [:named_table, :public])
    assert {:ok, :fine} = Guard.run(Fixture, :f, [:ok], server: :guard_test_ctr)
    assert {:ok, :fine} = Guard.run(Fixture, :f, [:ok], server: :guard_test_ctr)
    assert :ets.lookup(:guard_test_ctr, Fixture) == [{Fixture, 2}]
    assert :ets.lookup(:guard_test_ctr, :total) == [{:total, 2}]
  end

  test "a result holding a local fun is rejected with a notice" do
    start_supervised!(Notices)
    Notices.subscribe()
    assert Guard.run(Fixture, :f, [:fun], @nosrv) == {:failed, {:local_fun, Fixture, [:cb]}}
    assert_receive {:herdr_reload, {:rejected, Fixture, [:cb]}}
    assert {:ok, %{cb: _}} = Guard.run(Fixture, :f, [:fun], [scan: false] ++ @nosrv)
  end

  test "a re-run that returns a local fun again is not a second rejected notice" do
    fun_src = fn n -> "defmodule Toy.A do\n  def f(:fun), do: %{n: #{n}, cb: fn -> 1 end}\nend\n" end
    dir = toy!(:toy_g_rerun_fun, %{"lib/a.ex" => fun_src.(1)})
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", fun_src.(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])
    start_supervised!(Notices)
    Notices.subscribe()

    capture_log(fn ->
      assert {:failed, {:local_fun, Toy.A, [:cb]}, 2} =
               Guard.run_twice_attributed(Toy.A, :f, [:fun], scan: true)
    end)

    assert_receive {:herdr_reload, {:rejected, Toy.A, [:cb]}}
    refute_receive {:herdr_reload, {:rejected, _, _}}, 100
  end

  test "a raise rolls back only the batch that owns the failing module" do
    dir = toy!(:toy_g_attr, %{"lib/a.ex" => a_src(1), "lib/b.ex" => b_src(1)})
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", a_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])
    HerdrReload.ReloadCase.write_source!(dir, "lib/b.ex", b_src(2))
    assert {:ok, %Batch{id: 3}} = Server.reload([path(dir, "b")])

    assert {:ok, 2} = Guard.run(Toy.A, :f, [:ok])

    assert {:failed, {:raise, %RuntimeError{message: "boom 2"}, _}} =
             Guard.run(Toy.A, :f, [:boom])

    [b3, b2, b1] = Server.batches()
    assert b2.rolled_back and b2.failures == 1
    refute b3.rolled_back or b1.rolled_back
    assert Guard.run(Toy.A, :f, [:ok]) == {:ok, 1}
    assert Guard.run(Toy.B, :g, []) == {:ok, 2}
  end

  test "run_twice re-runs once on the rolled-back code" do
    dir = toy!(:toy_g_twice, %{"lib/a.ex" => a_src(1)})
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", String.replace(a_src(2), "do: 2", "do: raise(\"v2\")"))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])

    log = capture_log(fn -> assert Guard.run_twice(Toy.A, :f, [:ok]) == {:ok, 1} end)
    assert log =~ "Toy.A.f/1 failed: ** (RuntimeError) v2"
    assert [%Batch{id: 2, rolled_back: true}, _] = Server.batches()
  end

  test "run_twice does not re-run an unattributed failure and logs it once" do
    calls = :counters.new(1, [])

    log =
      capture_log(fn ->
        assert {:failed, {:raise, %RuntimeError{}, _} = f} =
                 Guard.run_twice(Fixture, :f, [{:count_boom, calls}], @nosrv)

        assert Guard.message(f) == "** (RuntimeError) boom"
      end)

    assert :counters.get(calls, 1) == 1
    assert length(String.split(log, "GuardTest.Fixture.f/1 failed")) == 2
    assert Guard.message({:timeout, 50, []}) == "timed out after 50ms"
    assert Guard.message({:local_fun, Fixture, [:cb]}) =~ "local fun"
  end

  test "run_twice re-runs an attributed failure once and returns the second failure" do
    dir = toy!(:toy_g_twice_fail, %{"lib/a.ex" => a_src(1)})
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", a_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])

    log =
      capture_log(fn ->
        assert {:failed, {:raise, %RuntimeError{message: "boom 1"}, _}} =
                 Guard.run_twice(Toy.A, :f, [:boom])
      end)

    assert log =~ "boom 2"
    assert length(String.split(log, "Toy.A.f/1 failed")) == 3
  end

  test "a failing re-run after a rollback rolls back nothing more" do
    dir = toy!(:toy_g_rerun, %{"lib/a.ex" => a_src(1)})
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", a_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", a_src(3))
    assert {:ok, %Batch{id: 3}} = Server.reload([path(dir, "a")])

    # batch 3's code fails, batch 2's code fails the same call: only 3 rolls back
    capture_log(fn ->
      assert {:failed, {:raise, %RuntimeError{message: "boom 2"}, _}, 3} =
               Guard.run_twice_attributed(Toy.A, :f, [:boom])
    end)

    assert [%Batch{id: 3, rolled_back: true}, %Batch{id: 2, rolled_back: false} | _] =
             Server.batches()

    assert Guard.run(Toy.A, :f, [:ok]) == {:ok, 2}
  end

  test "run_twice_attributed names the batch the first run rolled back" do
    dir = toy!(:toy_g_twice_attr, %{"lib/a.ex" => a_src(1)})
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", a_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])

    capture_log(fn ->
      assert {:failed, {:raise, %RuntimeError{message: "boom 1"}, _}, 2} =
               Guard.run_twice_attributed(Toy.A, :f, [:boom])

      assert {:failed, {:raise, _, _}, nil} =
               Guard.run_twice_attributed(Toy.A, :f, [:boom], @nosrv)
    end)
  end

  test "an exit nested stack attributes to the modules inside it" do
    assert {:failed, {:exit, {:inner, _}, _}} = Guard.run(Fixture, :f, [:nested_exit], @nosrv)

    assert Guard.stack_modules(
             Fixture,
             {:exit, {:inner, [{Nested.Mod, :g, 1, []}]}, [{Other, :h, 0, []}]}
           ) ==
             [Fixture, Other, Nested.Mod]
  end

  test "a batch exercised past its window is no longer blamed" do
    toy!(:toy_g_window, %{"lib/a.ex" => a_src(1)}, exercise_n: 3, exercise_floor_ms: 0)
    for _ <- 1..3, do: assert({:ok, 1} = Guard.run(Toy.A, :f, [:ok]))
    assert {:failed, {:raise, _, _}} = Guard.run(Toy.A, :f, [:boom])
    assert [%Batch{id: 1, rolled_back: false, failures: 0}] = Server.batches()
    assert Server.fail([Toy.A], :again) == :unattributed
  end

  test "a guarded failure while the server compiles waits and still fails" do
    dir = toy!(:toy_g_busy, %{"lib/a.ex" => a_src(1), "lib/b.ex" => b_src(1)})

    HerdrReload.ReloadCase.write_source!(
      dir,
      "lib/b.ex",
      "defmodule Toy.B do\n  Process.sleep(300)\n  def g, do: 2\nend\n"
    )

    reload = Task.async(fn -> Server.reload([path(dir, "b")]) end)
    # Toy.B sleeps 300ms while compiling, so the server is mid-reload here
    Process.sleep(50)

    assert {:current_stacktrace, [frame | _]} =
             Process.info(Process.whereis(Server), :current_stacktrace)

    refute match?({:gen_server, :loop, _, _}, frame)
    assert {:failed, {:raise, _, _}} = Guard.run(Toy.A, :f, [:boom])
    assert {:ok, %Batch{id: 2}} = Task.await(reload, 30_000)
  end

  test "a failure during a compile never blames the batch that compile then loads" do
    dir = toy!(:toy_g_window_fail, %{"lib/a.ex" => a_src(1)}, exercise_n: 3, exercise_floor_ms: 0)
    # batch 1 is exercised past its window: only batch 2 could be blamed
    for _ <- 1..3, do: assert({:ok, 1} = Guard.run(Toy.A, :f, [:ok]))
    slow = String.replace(a_src(2), "defmodule Toy.A do\n", "defmodule Toy.A do\n  Process.sleep(300)\n")
    HerdrReload.ReloadCase.write_source!(dir, "lib/a.ex", slow)
    reload = Task.async(fn -> Server.reload([path(dir, "a")]) end)
    Process.sleep(50)

    # fails mid-compile (old code, or no code at all while Mix rebuilds Toy.A); its
    # attribution waits for the compile, then must not land on batch 2
    assert {:failed, _} = Guard.run(Toy.A, :f, [:boom])
    assert {:ok, %Batch{id: 2}} = Task.await(reload, 30_000)
    assert [%Batch{id: 2, rolled_back: false, failures: 0} | _] = Server.batches()
    assert Guard.run(Toy.A, :f, [:ok]) == {:ok, 2}
  end

  test "a trapping caller gets no stray messages from budgeted calls" do
    Process.flag(:trap_exit, true)
    assert {:ok, :fine} = Guard.run(Fixture, :f, [:ok], [budget_ms: 1_000] ++ @nosrv)

    assert {:failed, {:timeout, 20, _}} =
             Guard.run(Fixture, :f, [:loop], [budget_ms: 20] ++ @nosrv)

    Process.sleep(20)
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "an externally killed worker fails the call and spares the caller" do
    killer = spawn(fn -> receive do: ({:worker, pid} -> Process.exit(pid, :kill)) end)

    assert Guard.run(Fixture, :f, [{:report, killer}], [budget_ms: 5_000] ++ @nosrv) ==
             {:failed, {:exit, :killed, []}}
  end

  test "killing the caller kills the worker" do
    me = self()

    caller =
      spawn(fn -> Guard.run(Fixture, :f, [{:report, me}], [budget_ms: 60_000] ++ @nosrv) end)

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  test "inline stacks attribute to the called module, not Guard or its caller" do
    assert {:failed, failure} = Guard.run(Fixture, :f, [:boom], @nosrv)
    mods = Guard.stack_modules(Fixture, failure)
    assert Fixture in mods
    refute Guard in mods
    refute __MODULE__ in mods
  end

  test "a GenServer.call exit digs out the callee stack" do
    reason = {{%RuntimeError{}, [{Deep.Mod, :x, 0, []}]}, {GenServer, :call, [:srv, :msg, 5_000]}}
    assert Deep.Mod in Guard.stack_modules(Fixture, {:exit, reason, []})
  end

  test "a server dying during attribution does not crash the caller" do
    fake = spawn(fn -> receive do: (_ -> exit(:dead)) end)
    Process.register(fake, :guard_test_dying_server)

    assert {:failed, {:raise, _, _}} =
             Guard.run(Fixture, :f, [:boom], server: :guard_test_dying_server)
  end
end
