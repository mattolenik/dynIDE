defmodule HerdrReload.ServerTest do
  use HerdrReload.ReloadCase, async: false

  import ExUnit.CaptureIO

  alias HerdrReload.{Batch, Compiler, Notices, Server}

  @counter """
  defmodule Toy.Counter do
    use GenServer
    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}
    def handle_call(:get, _from, n), do: {:reply, {n, Toy.V.v()}, n}
    def handle_call(:inc, _from, n), do: {:reply, :ok, n + 1}
  end
  """

  @mods [Toy.V, Toy.W, Toy.X, Toy.Counter]

  setup do
    on_exit(fn ->
      for m <- @mods do
        :code.purge(m)
        :code.delete(m)
        :code.purge(m)
      end
    end)
  end

  defp v_src(n) do
    "defmodule Toy.V do\n  def v, do: #{n}\n  def loop, do: receive(do: (:stop -> :ok))\nend\n"
  end

  defp w_src(n), do: "defmodule Toy.W do\n  def w, do: #{n}\nend\n"
  defp path(dir, f), do: Path.join(dir, "lib/#{f}.ex")

  # dynamic calls: the toy modules do not exist when this test compiles
  defp v, do: Module.concat([Toy.V]).v()
  defp w, do: Module.concat([Toy.W]).w()

  # starts a server on a fresh toy project and loads it as batch 1
  defp toy!(app, server_opts \\ []) do
    dir =
      HerdrReload.ReloadCase.toy_project!(app, %{
        "lib/v.ex" => v_src(1),
        "lib/w.ex" => w_src(1),
        "lib/counter.ex" => @counter
      })

    opts = [project_dir: dir, app: app]

    on_exit(fn ->
      for d <- Map.values(Compiler.ebin_dirs(opts)), do: :code.del_path(String.to_charlist(d))
    end)

    srv = start_supervised!({Server, opts ++ server_opts})
    assert {:ok, %Batch{id: 1}} = Server.reload(Enum.map(~w(v w counter), &path(dir, &1)))
    {dir, srv}
  end

  test "reload loads the edited module and keeps a live genserver's state" do
    {dir, _} = toy!(:toy_s_gen)
    {:ok, pid} = Module.concat([Toy.Counter]).start_link(41)
    :ok = GenServer.call(pid, :inc)
    assert GenServer.call(pid, :get) == {42, 1}

    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2, modules: [Toy.V]}} = Server.reload([path(dir, "v")])
    assert :code.is_loaded(Toy.V) != false
    assert v() == 2
    assert GenServer.call(pid, :get) == {42, 2}

    assert Server.rollback(1) == {:ok, [2]}
    assert v() == 1
    assert GenServer.call(pid, :get) == {42, 1}
    assert :sys.get_state(pid) == 42
    assert [%Batch{id: 2, rolled_back: true} | _] = Server.batches()
  end

  test "noop when nothing changed" do
    {dir, _} = toy!(:toy_s_noop)
    assert Server.reload([path(dir, "v")]) == :noop
  end

  test "ring evicts beyond depth" do
    {dir, _} = toy!(:toy_s_ring, ring_depth: 2)

    for n <- 2..3 do
      HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(n))
      assert {:ok, _} = Server.reload([path(dir, "v")])
    end

    assert Enum.map(Server.batches(), & &1.id) == [3, 2]
  end

  test "fail attributes to the live batch containing the module" do
    start_supervised!(Notices)
    {dir, _} = toy!(:toy_s_fail)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v")])
    HerdrReload.ReloadCase.write_source!(dir, "lib/w.ex", w_src(2))
    assert {:ok, %Batch{id: 3}} = Server.reload([path(dir, "w")])

    Notices.subscribe()
    assert Server.fail([Toy.V], :boom) == {:rolled_back, 2}
    assert_receive {:herdr_reload, {:rolled_back, 2, [Toy.V], :boom}}
    assert v() == 1
    assert w() == 2

    [b3, b2, _] = Server.batches()
    assert b2.rolled_back and b2.failures == 1
    refute b3.rolled_back
    assert Server.fail([Elixir.Nope], :boom) == :unattributed
  end

  test "a batch whose modules are never guarded closes after floor and total" do
    {dir, _} = toy!(:toy_s_close, exercise_n: 2, exercise_floor_ms: 0)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v")])
    :ets.update_counter(Server, :total, 2, {:total, 0})
    assert Server.fail([Toy.V], :boom) == :unattributed
  end

  test "overlapping rollback loads each module once, from the oldest batch" do
    start_supervised!(Notices)
    {dir, _} = toy!(:toy_s_overlap)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    HerdrReload.ReloadCase.write_source!(dir, "lib/w.ex", w_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v"), path(dir, "w")])
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(3))
    HerdrReload.ReloadCase.write_source!(dir, "lib/x.ex", "defmodule Toy.X do\nend\n")
    assert {:ok, %Batch{id: 3}} = Server.reload([path(dir, "v"), path(dir, "x")])

    # holds batch-3 V code: a second load of V would block on its purge
    pid = spawn(Module.concat([Toy.V]), :loop, [])
    Process.sleep(20)
    Notices.subscribe()

    assert Server.fail([Toy.W], :boom) == {:rolled_back, 2}
    refute_received {:herdr_reload, {:purge_blocked, _, _}}
    assert v() == 1
    assert w() == 1
    refute :code.is_loaded(Toy.X)

    assert [%Batch{id: 3, rolled_back: true}, %Batch{id: 2, rolled_back: true}, _] =
             Server.batches()

    assert Process.alive?(pid)
  end

  test "an unrelated reload right after a rollback keeps the rolled-back code" do
    {dir, _} = toy!(:toy_s_after_rb)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v")])
    assert Server.rollback(1) == {:ok, [2]}

    HerdrReload.ReloadCase.write_source!(dir, "lib/w.ex", w_src(2))
    assert {:ok, %Batch{id: 3, modules: [Toy.W]}} = Server.reload([path(dir, "w")])
    assert v() == 1
  end

  test "compile error broadcasts and records no batch" do
    start_supervised!(Notices)
    {dir, _} = toy!(:toy_s_err)
    Notices.subscribe()

    HerdrReload.ReloadCase.write_source!(
      dir,
      "lib/v.ex",
      "defmodule Toy.V do\n  def v, do: (\nend\n"
    )

    {res, _} = with_io(:stderr, fn -> Server.reload([path(dir, "v")]) end)
    assert {:error, [_ | _]} = res
    assert_receive {:herdr_reload, {:compile_error, [_ | _]}}
    assert Enum.map(Server.batches(), & &1.id) == [1]
    assert v() == 1
  end

  test "state_at_load lands in the batch and counters table is named after the server" do
    {_dir, srv} = toy!(:toy_s_state, state_at_load: fn -> :snap end)
    assert [%Batch{state_at_load: :snap}] = Server.batches()
    assert Server.counters_table(srv) == Server
    assert :ets.info(Server, :protection) == :public
  end
end
