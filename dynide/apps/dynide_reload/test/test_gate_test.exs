defmodule DynideReload.TestGateTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideReload.{Notices, TestGate}

  setup do
    root = Path.join(System.tmp_dir!(), "gate_#{System.unique_integer([:positive])}")
    for f <- ~w(apps/a/lib/a/x.ex apps/a/lib/a/y.ex apps/a/lib/a/w.ex apps/a/test/w_test.exs apps/a/test/a/x_test.exs apps/b/lib/z.ex) do
      File.mkdir_p!(Path.dirname(Path.join(root, f)))
      File.write!(Path.join(root, f), "")
    end

    start_supervised!(Notices)
    gate = start_supervised!({TestGate, name: :gate_under_test})
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, gate: gate}
  end

  defp p(root, rel), do: Path.join(root, rel)

  test "tests_for maps lib files, test files and ignores the rest", %{root: root} do
    a = p(root, "apps/a")
    assert TestGate.tests_for([p(root, "apps/a/lib/a/x.ex")], root) == %{a => ["test/a/x_test.exs"]}
    assert TestGate.tests_for([p(root, "apps/a/test/a/x_test.exs")], root) ==
             %{a => ["test/a/x_test.exs"]}

    both = [p(root, "apps/a/lib/a/x.ex"), p(root, "apps/a/test/a/x_test.exs")]
    assert TestGate.tests_for(both, root) == %{a => ["test/a/x_test.exs"]}
    # the repo's convention drops the app-namespace dir
    assert TestGate.tests_for([p(root, "apps/a/lib/a/w.ex")], root) == %{a => ["test/w_test.exs"]}
    assert TestGate.tests_for([p(root, "apps/a/lib/a/y.ex")], root) == %{}
    assert TestGate.tests_for([p(root, "apps/b/lib/z.ex")], root) == %{}
    assert TestGate.tests_for([p(root, "config/config.exs"), "/elsewhere/x.ex"], root) == %{}
  end

  test "mode round-trips through the app env" do
    old = TestGate.mode()
    on_exit(fn -> TestGate.set_mode(old) end)
    TestGate.set_mode(:gate)
    assert TestGate.mode() == :gate
    TestGate.set_mode(:off)
    assert TestGate.mode() == :off
  end

  defp opts(root, runner_result, mode) do
    me = self()

    [
      mode: mode,
      root: root,
      server: :gate_under_test,
      reload: fn paths ->
        send(me, {:reload, paths})
        :reloaded
      end,
      runner: fn dir, args, env, _t ->
        send(me, {:ran, dir, args, env})
        runner_result
      end
    ]
  end

  test "off reloads once and never runs tests", %{root: root} do
    paths = [p(root, "apps/a/lib/a/x.ex")]
    assert TestGate.reload(paths, opts(root, {"", 0}, :off)) == :reloaded
    assert_received {:reload, ^paths}
    refute_received {:ran, _, _, _}
  end

  test "gate with a failing runner never reloads and broadcasts running then failed", %{root: root} do
    Notices.subscribe()
    paths = [p(root, "apps/a/lib/a/x.ex")]
    out = "3 tests, 2 failures\n"
    assert {:tests, :failed, %{failures: 2, files: 1}} =
             TestGate.reload(paths, opts(root, {out, 2}, :gate))

    refute_received {:reload, _}
    assert_received {:ran, _, ["test", "test/a/x_test.exs"], _}
    assert_received {:dynide_reload, {:tests, :running, %{files: 1}}}
    assert_received {:dynide_reload, {:tests, :failed, %{files: 1, failures: 2}}}
  end

  test "gate with a passing runner reloads", %{root: root} do
    Notices.subscribe()
    paths = [p(root, "apps/a/lib/a/x.ex")]
    assert TestGate.reload(paths, opts(root, {"3 tests, 0 failures\n", 0}, :gate)) == :reloaded
    assert_received {:dynide_reload, {:tests, :passed, %{failures: 0}}}
  end

  test "gate without mapped tests reloads and broadcasts :none, logged once", %{root: root} do
    Notices.subscribe()
    paths = [p(root, "apps/a/lib/a/y.ex")]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert TestGate.reload(paths, opts(root, {"", 1}, :gate)) == :reloaded
      end)

    refute_received {:ran, _, _, _}
    # so the chrome clears a "tests..." left by an earlier stale run
    assert_received {:dynide_reload, {:tests, :none, %{files: 0, failures: 0, ms: 0}}}
    refute_received {:dynide_reload, _}
    assert [_] = Regex.scan(~r/herdr-event tests ts=\d+ result=none files=0 failures=0 ms=0/, log)
  end

  test "the root is computed once at init and used when no :root is given", %{root: root, gate: gate} do
    assert %{root: init_root} = :sys.get_state(gate)
    assert init_root == Path.dirname(Mix.Project.project_file())
    # later lookups use the state, not Mix.Project at call time
    :sys.replace_state(gate, &%{&1 | root: root})
    o = Keyword.delete(opts(root, {"1 test, 0 failures\n", 0}, :gate), :root)
    assert TestGate.reload([p(root, "apps/a/lib/a/x.ex")], o) == :reloaded
    assert_received {:ran, _, ["test", "test/a/x_test.exs"], _}
  end

  test "an exit status without a summary line is an error; a timeout too" do
    t = %{"/d" => ["test/x_test.exs"]}
    assert {:error, _} = TestGate.run(t, runner: fn _, _, _, _ -> {"boom", 1} end)
    assert {:error, _} = TestGate.run(t, runner: fn _, _, _, _ -> :timeout end)
    assert {:passed, %{failures: 0}} = TestGate.run(t, runner: fn _, _, _, _ -> {"", 0} end)
  end

  test "run passes MIX_ENV=test and unsets the live VM's env" do
    me = self()
    runner = fn _, _, env, _ ->
      send(me, {:env, env})
      {"1 test, 0 failures", 0}
    end
    TestGate.run(%{"/d" => ["test/x_test.exs"]}, runner: runner)
    assert_received {:env, env}
    assert {"MIX_ENV", "test"} in env
    for v <- ~w(HERDR_BROKER_SOCK HERDR_LIVE_GEN HERDR_LIVE_API HERDR_LIVE_LOG
                HERDR_LIVE_RUNTIME_DIR HERDR_LIVE_HEADLESS),
        do: assert({v, nil} in env)
  end

  test "the default runner kills a command over the timeout", %{root: root} do
    exe = Path.join(root, "slow.sh")
    File.write!(exe, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(exe, 0o755)
    # the OS pid the runner started, from its own port_info call (Port.info compiles to
    # it): a pid file the script writes can be late under load, or never written if the
    # kill comes first. A process cannot be its own tracer: a relay forwards the trace.
    test = self()
    relay = fn relay -> receive(do: (m -> send(test, m) && relay.(relay))) end
    :erlang.trace_pattern({:erlang, :port_info, 2}, [{:_, [], [{:return_trace}]}], [:local])
    on_exit(fn -> :erlang.trace_pattern({:erlang, :port_info, 2}, false, [:local]) end)
    :erlang.trace(self(), true, [:call, {:tracer, spawn_link(fn -> relay.(relay) end)}])
    t0 = System.monotonic_time(:millisecond)
    t = %{root => ["test/x_test.exs"]}
    assert {:error, _} = TestGate.run(t, exe: exe, timeout_ms: 500)
    assert System.monotonic_time(:millisecond) - t0 < 5_000
    :erlang.trace(self(), false, [:call])
    assert_receive {:trace, _, :return_from, {:erlang, :port_info, 2}, {:os_pid, pid}}, 5_000
    {_, status} = System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true)
    assert status != 0
  end

  describe "blocked set" do
    test "a failed save blocks the next batch of an unmapped file until its tests pass", %{root: root} do
      Notices.subscribe()
      x = p(root, "apps/a/lib/a/x.ex")
      y = p(root, "apps/a/lib/a/y.ex")
      fail = {"1 test, 1 failure\n", 2}
      assert {:tests, :failed, _} = TestGate.reload([x], opts(root, fail, :gate))

      # y has no tests but x's are blocked: they run, and still fail
      assert {:tests, :failed, _} = TestGate.reload([y], opts(root, fail, :gate))
      refute_received {:reload, _}

      # fixed: the blocked tests pass, the batch reloads, the set is cleared
      assert TestGate.reload([y], opts(root, {"1 test, 0 failures\n", 0}, :gate)) == :reloaded
      assert_received {:reload, [^y, ^x]}
      assert TestGate.reload([y], opts(root, fail, :gate)) == :reloaded
    end

    test "set_mode(:off) clears the blocked set", %{root: root} do
      old = TestGate.mode()
      on_exit(fn -> TestGate.set_mode(old) end)
      start_supervised!(TestGate, id: :named)
      x = p(root, "apps/a/lib/a/x.ex")
      y = p(root, "apps/a/lib/a/y.ex")
      o = Keyword.put(opts(root, {"1 test, 1 failure\n", 2}, :gate), :server, TestGate)
      assert {:tests, :failed, _} = TestGate.reload([x], o)
      TestGate.set_mode(:off)
      _ = :sys.get_state(TestGate)
      assert TestGate.reload([y], o) == :reloaded
    end

    test "a path saved again while its tests ran is not reloaded", %{root: root} do
      Notices.subscribe()
      x = p(root, "apps/a/lib/a/x.ex")
      o = opts(root, {"1 test, 0 failures\n", 0}, :gate)
      runner = fn _, _, _, _ ->
        File.write!(x, "changed")
        {"1 test, 0 failures\n", 0}
      end
      assert {:tests, :stale, _} = TestGate.reload([x], Keyword.put(o, :runner, runner))
      refute_received {:reload, _}
      # no passed result is broadcast for a skipped reload
      assert_received {:dynide_reload, {:tests, :running, _}}
      refute_received {:dynide_reload, {:tests, :passed, _}}
    end

    test "another source saved during the run stops the reload; it is then gated", %{root: root} do
      x = p(root, "apps/a/lib/a/x.ex")
      z = p(root, "apps/b/lib/z.ex")
      File.mkdir_p!(Path.join(root, "apps/b/test"))
      File.write!(Path.join(root, "apps/b/test/z_test.exs"), "")
      ok = {"1 test, 0 failures\n", 0}
      slow = fn _, _, _, _ ->
        File.write!(z, "broken")
        ok
      end
      assert {:tests, :stale, _} = TestGate.reload([x], Keyword.put(opts(root, ok, :gate), :runner, slow))
      refute_received {:reload, _}

      # z's queued batch is gated, fails, and nothing is loaded
      assert {:tests, :failed, _} = TestGate.reload([z], opts(root, {"1 test, 1 failure\n", 2}, :gate))
      refute_received {:reload, _}
    end

    test "a blocked path that now passes is reloaded with the batch", %{root: root} do
      x = p(root, "apps/a/lib/a/x.ex")
      y = p(root, "apps/a/lib/a/y.ex")
      TestGate.reload([x], opts(root, {"1 test, 1 failure\n", 2}, :gate))
      assert TestGate.reload([y], opts(root, {"1 test, 0 failures\n", 0}, :gate)) == :reloaded
      assert_received {:reload, all}
      assert Enum.sort(all) == Enum.sort([x, y])
    end
  end
end
