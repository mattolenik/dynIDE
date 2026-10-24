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

  # counts the server's Compiler.compile/4 calls (each one is a Mix run)
  defp trace_compiles(srv) do
    :erlang.trace_pattern({Compiler, :compile, 4}, true, [:local])
    :erlang.trace(srv, true, [:call])
  end

  defp compiles(n \\ 0) do
    receive do
      {:trace, _, :call, {Compiler, :compile, _}} -> compiles(n + 1)
    after
      0 -> n
    end
  end

  defp posix_mtime(p), do: File.stat!(p, time: :posix).mtime

  test "a path unchanged since its last compile is dropped without a Mix run" do
    {dir, srv} = toy!(:toy_s_digest)
    p = path(dir, "v")
    # a same-second edit: the compiler back-dates the source once
    m = posix_mtime(p)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    File.touch!(p, m)
    trace_compiles(srv)
    assert {:ok, %Batch{id: 2}} = Server.reload([p])
    assert posix_mtime(p) == m - 1

    # our own back-date (or a duplicate event) arrives: no Mix run, no further touch
    assert Server.reload([p]) == :noop
    assert posix_mtime(p) == m - 1
    assert compiles() == 1

    # a real edit, even in the same second, still compiles
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(3))
    File.touch!(p, m - 1)
    assert {:ok, %Batch{id: 3}} = Server.reload([p])
    assert v() == 3
  end

  test "watcher + server: one same-second save is one compile, our touch does not loop" do
    start_supervised!(Notices)
    {dir, srv} = toy!(:toy_s_watch)
    p = path(dir, "v")
    m = posix_mtime(p)

    # the backend reports realpaths (tmp is a symlink on macOS); the server's paths are
    # spelled from project_dir, as the real watcher's are in a non-symlinked project
    {real, 0} = System.cmd("pwd", ["-P"], cd: dir)
    real = String.trim(real)
    respell = fn ps -> Enum.map(ps, &String.replace_prefix(&1, real, dir)) end

    start_supervised!(
      {HerdrReload.Watcher,
       dirs: [Path.join(dir, "lib")], on_batch: &Server.reload(srv, respell.(&1))}
    )

    # let the OS backend arm before the first write
    Process.sleep(300)
    Notices.subscribe()
    trace_compiles(srv)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    File.touch!(p, m)
    assert_receive {:herdr_reload, {:loaded, 2, [Toy.V]}}, 3000
    # well past the 50ms debounce: the back-date's own event must not compile again
    Process.sleep(1500)
    refute_received {:herdr_reload, {:loaded, _, _}}
    assert compiles() == 1
    assert posix_mtime(p) == m - 1
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

  test "a failure stamped before a batch's load cannot blame that batch" do
    {dir, _} = toy!(:toy_s_stamp, exercise_n: 2, exercise_floor_ms: 0)
    # batch 1 is exercised past its window: only batch 2 could be blamed
    :ets.update_counter(Server, :total, 2, {:total, 0})
    before = System.monotonic_time(:millisecond)
    Process.sleep(2)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v")])

    assert Server.fail(Server, [Toy.V], :boom, before) == :unattributed
    assert v() == 2
    assert Server.fail([Toy.V], :boom) == {:rolled_back, 2}
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

  defp beam!(app, dir, mod),
    do: Path.join(Compiler.ebin_dirs(project_dir: dir, app: app)[app], "#{mod}.beam")

  defp rejected(dir, id, mod),
    do: Path.wildcard(Path.join(dir, "**/herdr_reload/rejected/*-#{id}/#{mod}.beam"))

  defp unload(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  test "rollback restores the previous beam on disk and keeps the bad one" do
    {dir, _} = toy!(:toy_s_disk)
    p = beam!(:toy_s_disk, dir, Toy.V)
    prev = File.read!(p)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v")])
    bad = File.read!(p)
    assert Server.rollback(1) == {:ok, [2]}

    assert File.read!(p) == prev
    assert [r] = rejected(dir, 2, Toy.V)
    assert File.read!(r) == bad

    # the restored beam is not a change, and autoloads the old code
    HerdrReload.ReloadCase.write_source!(dir, "lib/w.ex", w_src(2))
    assert {:ok, %Batch{id: 3, modules: [Toy.W]}} = Server.reload([path(dir, "w")])
    unload(Toy.V)
    assert v() == 1

    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(3))
    assert {:ok, %Batch{id: 4, modules: [Toy.V]}} = Server.reload([path(dir, "v")])
    assert v() == 3
  end

  test "a restarted server keeps earlier rejects and files its own beside them" do
    {dir, _} = toy!(:toy_s_disk_vm)
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, %Batch{id: 2}} = Server.reload([path(dir, "v")])
    assert Server.rollback(1) == {:ok, [2]}
    [r] = rejected(dir, 2, Toy.V)
    bad = File.read!(r)

    # a later VM run: batch ids start again at 1, then 2
    stop_supervised!(Server)
    Process.sleep(2)
    start_supervised!({Server, project_dir: dir, app: :toy_s_disk_vm})

    for n <- [3, 4] do
      HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(n))
      assert {:ok, _} = Server.reload([path(dir, "v")])
    end

    assert {:ok, [2, 1]} = Server.rollback(2)
    assert File.read!(r) == bad
    assert [_, _] = rejected(dir, 2, Toy.V)
  end

  # ruling 28: a promoted standby runs the code it loaded at boot, older than the disk
  test "start loads loaded modules whose beam on disk differs, never a NIF module" do
    x_src = fn n ->
      "defmodule Toy.X do\n  def x, do: #{n}\n  def load, do: :erlang.load_nif(~c\"none\", 0)\nend\n"
    end

    {dir, _} = toy!(:toy_s_stale)
    HerdrReload.ReloadCase.write_source!(dir, "lib/x.ex", x_src.(1))
    assert {:ok, _} = Server.reload([path(dir, "x")])
    old = for m <- [Toy.V, Toy.X], into: %{}, do: {m, File.read!(beam!(:toy_s_stale, dir, m))}

    # another VM (the primary) compiles v 2 and x 2 to disk
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    HerdrReload.ReloadCase.write_source!(dir, "lib/x.ex", x_src.(2))
    assert {:ok, _} = Server.reload([path(dir, "v"), path(dir, "x")])
    stop_supervised!(Server)

    # this VM still runs the code it loaded before (the standby's boot-time preload)
    for {m, bin} <- old do
      unload(m)
      {:module, ^m} = :code.load_binary(m, ~c"#{m}.beam", bin)
    end

    assert {v(), Module.concat([Toy.X]).x()} == {1, 1}
    looper = spawn(fn -> Module.concat([Toy.V]).loop() end)

    start_supervised!({Server, project_dir: dir, app: :toy_s_stale})
    # a call is served after the start-up sync
    assert Server.batches() == []
    assert v() == 2
    assert Module.concat([Toy.X]).x() == 1
    assert Process.alive?(looper)
    send(looper, :stop)

    # the disk is the server's cache: the same source again is no change
    assert Server.reload([path(dir, "v")]) == :noop
  end

  test "a module new in a rolled-back batch leaves only its rejected beam" do
    {dir, _} = toy!(:toy_s_disk_new)
    HerdrReload.ReloadCase.write_source!(dir, "lib/x.ex", "defmodule Toy.X do\nend\n")
    assert {:ok, %Batch{id: 2, modules: [Toy.X]}} = Server.reload([path(dir, "x")])
    p = beam!(:toy_s_disk_new, dir, Toy.X)
    bad = File.read!(p)
    assert Server.rollback(1) == {:ok, [2]}

    refute File.exists?(p)
    assert [r] = rejected(dir, 2, Toy.X)
    assert File.read!(r) == bad

    HerdrReload.ReloadCase.write_source!(dir, "lib/w.ex", w_src(2))
    assert {:ok, %Batch{id: 3, modules: [Toy.W]}} = Server.reload([path(dir, "w")])
    refute :code.is_loaded(Toy.X)
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

  test "last_rolled_back: the oldest batch of the newest rollback; provider from app env" do
    n = :counters.new(1, [])
    env = Application.get_env(:herdr_reload, HerdrReload, [])
    on_exit(fn -> Application.put_env(:herdr_reload, HerdrReload, env) end)

    Application.put_env(
      :herdr_reload,
      HerdrReload,
      Keyword.put(env, :state_at_load, {__MODULE__, :snap, [n]})
    )

    {dir, _} = toy!(:toy_s_last_rb)
    assert Server.last_rolled_back() == :none
    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(2))
    HerdrReload.ReloadCase.write_source!(dir, "lib/w.ex", w_src(2))

    assert {:ok, %Batch{id: 2, state_at_load: 2}} =
             Server.reload([path(dir, "v"), path(dir, "w")])

    HerdrReload.ReloadCase.write_source!(dir, "lib/v.ex", v_src(3))
    assert {:ok, %Batch{id: 3, state_at_load: 3}} = Server.reload([path(dir, "v")])

    # failing W rolls back 2 and 3 (3 shares V with 2): the state before both is batch 2's
    assert Server.fail([Toy.W], :boom) == {:rolled_back, 2}
    assert Server.last_rolled_back() == {:ok, 2, 2}
    assert Server.rollback(1) == {:ok, [1]}
    assert Server.last_rolled_back() == {:ok, 1, 1}
  end

  @doc false
  def snap(n) do
    :counters.add(n, 1, 1)
    :counters.get(n, 1)
  end
end
