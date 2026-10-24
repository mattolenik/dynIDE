defmodule HerdrReload.LoaderTest do
  use ExUnit.Case, async: false

  alias HerdrReload.{Loader, Notices}

  @mod HerdrReload.LoaderFixture

  # dynamic module reference: the fixture does not exist at compile time
  defp fixture, do: Module.concat([@mod])

  defp bin(v) do
    src = """
    defmodule #{inspect(@mod)} do
      def v, do: #{v}
      def start(name), do: spawn(fn -> Process.register(self(), name); loop() end)
      defp loop do
        receive do
          :never -> loop()
        end
      end
    end
    """

    [{@mod, b}] = Code.compile_string(src)
    # compile_string loads it; drop so Loader.load is the only loader
    :code.purge(@mod)
    :code.delete(@mod)
    :code.purge(@mod)
    b
  end

  setup do
    start_supervised!(Notices)
    Notices.subscribe()

    on_exit(fn ->
      :code.purge(@mod)
      :code.delete(@mod)
      :code.purge(@mod)
    end)
  end

  defp stuck_process do
    # compile both first: compiling purges whatever is loaded
    {b1, b2} = {bin(1), bin(2)}
    assert :ok = Loader.load(@mod, b1, [])
    pid = fixture().start(:loader_fixture_proc)
    assert :ok = Loader.load(@mod, b2, [])
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "load twice swaps behaviour" do
    {b1, b2} = {bin(1), bin(2)}
    assert :ok = Loader.load(@mod, b1, [])
    assert fixture().v() == 1
    assert :ok = Loader.load(@mod, b2, [])
    assert fixture().v() == 2
  end

  test "load nil unloads" do
    assert :ok = Loader.load(@mod, bin(1), [])
    assert :ok = Loader.load(@mod, nil, [])
    refute :code.is_loaded(@mod)
  end

  test "holders names the stuck process" do
    pid = stuck_process()

    assert [%{pid: ^pid, name: :loader_fixture_proc, initial_call: {:erlang, :apply, 2}}] =
             Loader.holders(@mod)
  end

  test "purge_old reports blocked holders and keeps them alive" do
    pid = stuck_process()
    assert {:blocked, [%{pid: ^pid}]} = Loader.purge_old(@mod, retries: 1, retry_ms: 1)
    assert_receive {:herdr_reload, {:purge_blocked, @mod, [%{pid: ^pid}]}}
    assert Process.alive?(pid)
  end

  test "allowlist hard-purges" do
    pid = stuck_process()
    ref = Process.monitor(pid)
    assert :ok = Loader.purge_old(@mod, retries: 1, retry_ms: 1, allowlist: [@mod])
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  test "load over deleted current code leaves the old code holder alone" do
    {b1, b2} = {bin(1), bin(2)}
    assert :ok = Loader.load(@mod, b1, [])
    pid = fixture().start(:loader_fixture_old)
    on_exit(fn -> Process.exit(pid, :kill) end)
    # what Mix does to a module it recompiles: current code becomes old
    true = :code.delete(@mod)

    assert :ok = Loader.load(@mod, b2, retries: 1, retry_ms: 1)
    assert fixture().v() == 2
    refute_received {:herdr_reload, {:purge_blocked, _, _}}
    assert Process.alive?(pid)
  end

  test "purge_old with no old code is ok" do
    assert :ok = Loader.purge_old(@mod, [])
  end
end
