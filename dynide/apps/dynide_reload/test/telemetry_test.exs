defmodule DynideReload.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DynideReload.Telemetry

  test "line renders bare values, lists and the timestamp" do
    line =
      Telemetry.line(:reload,
        batch: 3,
        fanout: 2,
        modules: [DynideServer.View, Foo.Bar],
        compile_ms: 41
      )

    assert line =~
             ~r/^herdr-event reload ts=\d{13} batch=3 fanout=2 modules=DynideServer.View,Foo.Bar compile_ms=41$/
  end

  test "values with quotes and newlines are quoted on one line" do
    assert Telemetry.line(:x, msg: "a \"b\"\nc") =~ ~s(msg="a \\"b\\" c")
  end

  test "long values are cut to 300 bytes inside quotes, never multi-line" do
    line = Telemetry.line(:x, msg: String.duplicate("é\n", 2500), k: 1)
    refute line =~ "\n"
    [_, quoted] = Regex.run(~r/msg="([^"]*)" k=1$/, line)
    assert byte_size(quoted) <= 300
    assert String.valid?(quoted)
  end

  test "a cut never leaves a dangling escape" do
    line = Telemetry.line(:x, msg: String.duplicate("\"", 400))
    assert line =~ ~r/msg="(\\"){149,150}"$/
  end

  test "event logs the line" do
    log = capture_log(fn -> Telemetry.event(:vm_stop, gen: 2) end)
    assert log =~ ~r/herdr-event vm_stop ts=\d{13} gen=2/
  end

  describe "from_notice/2" do
    test "loaded" do
      assert {:reload, kw} = Telemetry.from_notice({:loaded, 5, [A, B]}, compile_ms: 7)
      assert kw[:batch] == 5 and kw[:fanout] == 2 and kw[:modules] == [A, B]
      assert kw[:compile_ms] == 7
    end

    test "rolled back with a guard failure" do
      reason = {:raise, %RuntimeError{message: "x"}, []}
      assert {:rollback, kw} = Telemetry.from_notice({:rolled_back, 4, [M], reason}, [])
      assert kw[:reason] == :raise
      assert kw[:batch] == 4
      assert kw[:fanout] == 1
      assert kw[:detail] =~ "x"
    end

    test "rolled back manually or with load errors" do
      assert {:rollback, kw} = Telemetry.from_notice({:rolled_back, 1, [M], :manual}, [])
      assert kw[:reason] == :manual

      assert {:rollback, kw} =
               Telemetry.from_notice({:rolled_back, 1, [M], {{:exit, :x, []}, [{M, :bad}]}}, [])

      assert kw[:reason] == :exit
    end

    test "compile error" do
      diag = %{file: "/a/b.ex", position: {12, 3}, message: "m"}
      assert {:compile_error, kw} = Telemetry.from_notice({:compile_error, [diag]}, [])
      assert kw[:file] == "/a/b.ex"
      assert kw[:line] == 12
      assert kw[:count] == 1
      assert kw[:msg] == "m"
    end

    test "rejected, purge_blocked, synced and unknown" do
      assert {:rejected, [module: M, path: _]} =
               Telemetry.from_notice({:rejected, M, [:cb]}, [])

      assert {:purge_blocked, kw} = Telemetry.from_notice({:purge_blocked, M, [%{pid: self()}]}, [])
      assert kw[:module] == M

      assert {:sync, kw} = Telemetry.from_notice({:synced, [A]}, failed: 1)
      assert kw[:count] == 1 and kw[:failed] == 1 and kw[:modules] == [A]

      assert Telemetry.from_notice(:x, []) == nil
    end

    test "tests" do
      assert {:tests, kw} = Telemetry.from_notice({:tests, :failed, %{files: 2, failures: 1, ms: 9}}, [])
      assert kw == [result: :failed, files: 2, failures: 1, ms: 9]
      assert Telemetry.from_notice({:tests, :running, %{files: 2}}, []) == nil
    end
  end
end
