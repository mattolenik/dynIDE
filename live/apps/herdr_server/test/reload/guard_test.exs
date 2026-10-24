defmodule HerdrServer.Reload.GuardTest do
  use HerdrServer.ReloadCase, async: false

  alias HerdrServer.Reload.{Batch, Compiler, Guard, Notices, Server}

  defmodule Fixture do
    @moduledoc false
    def f(:ok), do: :fine
    def f(:boom), do: raise("boom")
    def f(:throw), do: throw(:t)
    def f(:exit), do: exit(:x)
    def f(:nested_exit), do: exit({:inner, [{Elixir.Nested.Mod, :g, 1, []}]})
    def f(:fun), do: %{cb: fn -> 1 end}
    def f(:loop), do: loop()
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
    dir = HerdrServer.ReloadCase.toy_project!(app, files)
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

  test "a raise rolls back only the batch that owns the failing module" do
    dir = toy!(:toy_g_attr, %{"lib/a.ex" => a_src(1), "lib/b.ex" => b_src(1)})
    HerdrServer.ReloadCase.write_source!(dir, "lib/a.ex", a_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "a")])
    HerdrServer.ReloadCase.write_source!(dir, "lib/b.ex", b_src(2))
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

    HerdrServer.ReloadCase.write_source!(
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
end
