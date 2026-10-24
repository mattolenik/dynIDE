defmodule HerdrServer.Persist.StoreRestoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HerdrServer.App.{Actions, Store, Ui}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Persist.{Disk, Load, Schema}
  alias HerdrServer.View.Frame

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp} do
    Store.reset()
    old = Application.get_env(:herdr_server, HerdrServer.Persist)
    cfg = %{dir: Path.join(tmp, "state"), name: "default"}
    Application.put_env(:herdr_server, HerdrServer.Persist, enabled: true, dir: cfg.dir)

    on_exit(fn ->
      Application.put_env(:herdr_server, HerdrServer.Persist, old)
      Store.reset()
    end)

    {:ok, cfg: cfg, tmp: tmp}
  end

  # three panes in two tabs: 1, 2 in tab 1; 3 alone in tab 2, active and focused
  defp app do
    {app, _} = Actions.init(%{cols: 80, rows: 24})
    {app, _} = Actions.split(app, :horizontal)
    {app, _} = Actions.new_tab(app)
    app
  end

  defp write!(cfg, app, facts) do
    :ok = Disk.write(cfg, Schema.capture(app, facts))
  end

  # what a stopped VM leaves behind: no mirror, the Store starting fresh
  defp restart_store do
    Store.reset()
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)
    # the disk restore runs in handle_continue: a call returns after it
    Store.snapshot()
  end

  defp opens, do: :sys.get_state(Fake.Keeper).next_id

  defp res(id) do
    {:ok, res} = Fake.Keeper.lookup(Rows.kernel_id(id))
    res
  end

  defp fact(cwd), do: %{cwd: cwd, command: ["vim"], hidden: false}

  test "a restart without a mirror restores layout, focus, cwds and scrollback", %{
    cfg: cfg,
    tmp: tmp
  } do
    [a, b, c] = for d <- ["a", "b", "c"], do: Path.join(tmp, d)
    for d <- [a, b, c], do: File.mkdir_p!(d)
    app = app()
    write!(cfg, app, %{1 => fact(a), 2 => fact(b), 3 => fact(Path.join(c, "gone"))})
    :ok = Disk.write_scrollback(cfg, 1, "restored-history", 80)
    {:ok, want, _} = Schema.restore(Schema.capture(app, %{}))

    before = opens()
    log = capture_log([level: :info], fn -> restart_store() end)
    got = Store.snapshot()

    assert got.session.workspaces == want.session.workspaces
    assert got.session.area == want.session.area
    assert got.session.next_id == want.session.next_id
    assert got.focus == want.focus and got.focus.pane == 3
    assert Map.keys(got.session.panes) == [1, 2, 3]

    assert opens() - before == 3
    assert Enum.map([1, 2, 3], &Fake.Pty.cwd(res(&1).pty)) == [a, b, c]
    assert Fake.Vt.read_text(res(1).vt, :screen) =~ "restored-history"
    refute Fake.Vt.read_text(res(2).vt, :screen) =~ "restored-history"
    assert log =~ ~r/persist_restore .*source=disk reason=boot panes=3 scrollback=1 ms=\d+/

    # the first client event resizes the restored app instead of initialising a new one
    :ok = Store.event({:resize, %{cols: 100, rows: 30, cell_px: nil}}, nil)
    assert opens() - before == 3
    after_event = Store.snapshot()
    assert after_event.session.workspaces |> hd() |> Map.get(:tabs) |> length() == 2

    assert after_event.session.area ==
             Frame.regions(%{cols: 100, rows: 30}, %Ui{}).panes
  end

  test "no file: an empty Store, initialised lazily by the first event", %{cfg: cfg} do
    refute File.exists?(Disk.session_path(cfg))
    log = capture_log([level: :info], fn -> restart_store() end)
    assert Store.snapshot() == nil
    assert log =~ "persist_restore"
    assert log =~ "source=none reason=boot"

    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    assert Map.keys(Store.snapshot().session.panes) == [1]
  end

  test "a Store restart with a mirror never reads the disk", %{cfg: cfg} do
    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    mirrored = Store.snapshot()
    assert eventually(fn -> HerdrServer.Mirror.app() != nil end)
    # a file with a different layout
    write!(cfg, app(), %{})

    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)

    assert Store.snapshot().session.workspaces == mirrored.session.workspaces
    assert [_] = Fake.Keeper.ids()
  end

  test "a file that does not decode: app stays nil, persist_error logged", %{cfg: cfg} do
    File.mkdir_p!(cfg.dir)
    File.write!(Disk.session_path(cfg), "not a term")
    log = capture_log([level: :info], fn -> restart_store() end)
    assert Store.snapshot() == nil
    assert Fake.Keeper.ids() == []
    assert log =~ ~r/persist_error .*op=read/
  end

  test "a snapshot the schema rejects: app stays nil, persist_error logged", %{cfg: cfg} do
    snap = Schema.capture(app(), %{})
    :ok = Disk.write(cfg, put_in(snap.focus.pane, 99))
    log = capture_log([level: :info], fn -> restart_store() end)
    assert Store.snapshot() == nil
    assert Fake.Keeper.ids() == []
    assert log =~ ~r/persist_error .*op=read reason=/
    assert length(Regex.scan(~r/persist_error/, log)) == 1

    # set aside, so the Writer cannot overwrite the only copy
    refute File.exists?(Disk.session_path(cfg))
    assert [moved] = File.ls!(cfg.dir)
    assert moved =~ ~r/^session\.default\.etf\.bad-\d+$/
  end

  test "a restored pane whose open fails is retried once in the Store's cwd", %{
    cfg: cfg,
    tmp: tmp
  } do
    a = Path.join(tmp, "a")
    File.mkdir_p!(a)
    write!(cfg, app(), %{1 => fact(a), 2 => fact(a), 3 => fact(a)})
    :ok = Fake.Keeper.fail_next_open(:enoent)
    log = capture_log([level: :info], fn -> restart_store() end)

    assert Map.keys(Store.snapshot().session.panes) == [1, 2, 3]
    assert Enum.map([1, 2, 3], &Fake.Pty.cwd(res(&1).pty)) == [File.cwd!(), a, a]
    assert log =~ ~r/persist_restore .*panes=3 /
  end

  test "persist_restore counts the panes that spawned, not the planned ones", %{cfg: cfg} do
    # no recorded cwd: no retry, the pane is dropped
    write!(cfg, app(), %{1 => fact(nil)})
    :ok = Fake.Keeper.fail_next_open(:enoent)
    log = capture_log([level: :info], fn -> restart_store() end)
    assert log =~ ~r/persist_restore .*source=disk .*panes=2 /
  end

  test "a raise while reading the file takes the error path" do
    state = %{app: nil, sizes: %{}}
    # a dir that is not a path: Disk.read (and set_aside) raise
    cfg = %{dir: 123, name: "t"}

    log =
      capture_log([level: :info], fn ->
        assert Load.run(state, cfg, fn _, _ -> flunk("no spawn") end) == state
      end)

    assert length(Regex.scan(~r/persist_error .*op=read reason=/, log)) == 1
  end

  test "a restore that crashes the Store sets the file aside on the next start", %{cfg: cfg} do
    on_exit(fn -> :persistent_term.erase({Load, :attempt}) end)
    write!(cfg, app(), %{})
    path = Disk.session_path(cfg)

    # a file that validates but whose restore raises: the marker is left behind
    assert_raise RuntimeError, fn ->
      Load.run(%{app: nil, sizes: %{}}, cfg, fn _, _ -> raise "boom" end)
    end

    assert :persistent_term.get({Load, :attempt}) == path

    log = capture_log([level: :info], fn -> restart_store() end)
    assert Store.snapshot() == nil
    assert Fake.Keeper.ids() == []
    assert :persistent_term.get({Load, :attempt}, nil) == nil
    refute File.exists?(path)
    assert [moved] = File.ls!(cfg.dir)
    assert moved =~ ~r/^session\.default\.etf\.bad-\d+$/
    assert length(Regex.scan(~r/persist_error .*op=read reason=restore_crashed/, log)) == 1
    # no continue: the file was not read again
    refute log =~ "persist_restore"
  end

  test "a completed restore leaves no marker", %{cfg: cfg} do
    write!(cfg, app(), %{})
    restart_store()
    assert Map.keys(Store.snapshot().session.panes) == [1, 2, 3]
    assert :persistent_term.get({Load, :attempt}, nil) == nil
  end

  defp eventually(fun, n \\ 50) do
    cond do
      fun.() ->
        true

      n == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, n - 1)
    end
  end
end
