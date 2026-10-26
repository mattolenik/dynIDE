defmodule DynideServer.ReloadNoticesTest.SyncedStub do
  @moduledoc false
  # stands in for DynideReload.Server: answers synced/0 with the given modules
  use GenServer
  def start_link(mods), do: GenServer.start_link(__MODULE__, mods, name: DynideReload.Server)
  @impl true
  def init({mods, batches}), do: {:ok, {mods, batches}}
  def init(mods), do: {:ok, {mods, []}}
  @impl true
  def handle_call(:synced, _from, {mods, _} = s), do: {:reply, mods, s}
  def handle_call(:batches, _from, {_, batches} = s), do: {:reply, batches, s}
end

defmodule DynideServer.ReloadNoticesTest do
  # Reload events reach a fake client's scene as the status line's :notice child.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.{Protocol, Scene}
  alias DynideServer.App.Store
  alias DynideServer.Handoff.{Link, Notice}
  alias DynideServer.{Mirror, RuntimeStatus}
  alias DynideServer.ReloadNotices
  alias DynideServer.ReloadNoticesTest.SyncedStub

  setup do
    reset()
    old = Application.get_env(:dynide_server, :notice_ms)
    start_supervised!(DynideReload.Notices)
    # resubscribe now instead of waiting for the bridge's retry tick
    send(ReloadNotices, :subscribe)
    :sys.get_state(ReloadNotices)

    on_exit(fn ->
      if old,
        do: Application.put_env(:dynide_server, :notice_ms, old),
        else: Application.delete_env(:dynide_server, :notice_ms)

      reset()
    end)
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(DynideServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(DynideServer.Client.Supervisor, pid)

    Store.reset()
    # the runtime status outlives a test: start each from an empty one
    Mirror.delete(:runtime_status)
    :sys.replace_state(ReloadNotices, &%{&1 | status: RuntimeStatus.new()})
  end

  defp client do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: %{cols: 80, rows: 24},
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, self(), GenServer.call(Protocol.endpoint(), {:attach, info})})
        relay(parent)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, ^pid, {:ok, _session, _}}
    assert_receive {^pid, {:scene, _}}, 500
    pid
  end

  defp relay(parent) do
    receive do
      msg -> send(parent, {self(), msg})
    end

    relay(parent)
  end

  defp notice_node(%Scene{chrome: chrome}) do
    status = Enum.find(chrome.children, &(&1.id == :status))
    Enum.find(status.children, &(&1.id == :notice))
  end

  defp next_notice(c) do
    assert_receive {^c, {:scene, s}}, 500
    notice_node(s)
  end

  # a reload event that changes the runtime status repaints once more, after its notice
  defp status_scene(c), do: assert_receive({^c, {:scene, _}}, 500)

  defp diag,
    do: %{file: Path.join(File.cwd!(), "lib/foo.ex"), position: {12, 3}, message: "undefined x"}

  test "each reload event kind becomes a status notice with its token" do
    c = client()

    cases = [
      {{:compile_error, [diag()]}, :error, "lib/foo.ex:12: undefined x"},
      {{:loaded, 4, [A, B]}, :muted, "reloaded 2 modules"},
      {{:rolled_back, 3, [A], :manual}, :warning, "rolled back batch 3 (1 modules): manual"},
      {{:rejected, Foo.Bar, [:state, :x]}, :warning, "rejected: local fun from Foo.Bar at"},
      {{:purge_blocked, Foo, [self()]}, :warning, "purge blocked: Foo"}
    ]

    for {event, token, prefix} <- cases do
      DynideReload.Notices.broadcast(event)
      assert_receive {^c, {:notice, %{text: text, source: :reload}}}, 500
      assert String.starts_with?(text, prefix), "#{inspect(event)}: #{text}"
      assert String.length(text) <= 80
      # the status line clips it to the cells left beside the runtime status
      assert %{role: :text, token: ^token, text: shown} = next_notice(c)
      assert String.starts_with?(text, shown) and String.length(shown) >= 18
      status_scene(c)
    end
  end

  test "a rollback reason from the guard is summarised and truncated" do
    reason = {:raise, RuntimeError.exception(String.duplicate("x", 200)), []}

    assert {:info, "tests passed (3 files)"} =
             ReloadNotices.format({:tests, :passed, %{files: 3, failures: 0, ms: 5}})

    assert {:warning, "tests error, not loaded"} =
             ReloadNotices.format({:tests, :error, %{files: 3, failures: 0, ms: 5}})

    {:warning, text} = ReloadNotices.format({:rolled_back, 7, [A, B], reason})
    assert text =~ "rolled back batch 7 (2 modules): ** (RuntimeError) xxx"
    assert String.length(text) == 80
  end

  test "info and warning notices expire; an error stays until replaced" do
    Application.put_env(:dynide_server, :notice_ms, info: 30, warning: 60)
    c = client()

    DynideReload.Notices.broadcast({:loaded, 1, [A]})
    assert %{token: :muted} = next_notice(c)
    status_scene(c)
    assert next_notice(c) == nil

    DynideReload.Notices.broadcast({:compile_error, [diag()]})
    assert %{token: :error} = next_notice(c)
    status_scene(c)
    refute_receive {^c, {:scene, _}}, 150

    DynideReload.Notices.broadcast({:loaded, 2, [A]})
    assert %{token: :muted, text: "reloaded 1 modules"} = next_notice(c)
    status_scene(c)
    assert next_notice(c) == nil
  end

  test "a non-reload protocol notice also renders and expires" do
    Application.put_env(:dynide_server, :notice_ms, info: 30, warning: 30)
    c = client()
    [{session, _}] = Registry.lookup(DynideServer.Client.Registry, :clients)
    send(session, {:notice, %{level: :error, text: "could not start pane 2"}})
    assert_receive {^c, {:notice, %{level: :error}}}
    assert %{token: :error, text: "could not start pane 2"} = next_notice(c)
    # only reload errors are sticky
    assert next_notice(c) == nil
  end

  test "a repeated notice re-arms its timer without re-pushing the scene" do
    Application.put_env(:dynide_server, :notice_ms, info: 120, warning: 120)
    c = client()
    DynideReload.Notices.broadcast({:loaded, 1, [A]})
    assert %{token: :muted} = next_notice(c)
    status_scene(c)
    Process.sleep(70)
    DynideReload.Notices.broadcast({:loaded, 2, [A]})
    assert_receive {^c, {:notice, %{text: "reloaded 1 modules"}}}, 500
    # only the status changed (r2): one scene, the notice did not repaint
    status_scene(c)
    # the first timer would have fired 50 ms from now
    refute_receive {^c, {:scene, _}}, 100
    assert next_notice(c) == nil
  end

  describe "runtime status" do
    # a process registered as a session: gets what ReloadNotices fans out to clients
    defp fake_session do
      parent = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(DynideServer.Client.Registry, :clients, nil)
          send(parent, :registered)
          relay(parent)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive :registered
      pid
    end

    defp next_status(pid) do
      assert_receive {^pid, {:runtime_status, st}}, 500
      st
    end

    test "a reload event reaches every session and the mirror" do
      s = fake_session()
      DynideReload.Notices.broadcast({:loaded, 1, [M]})
      st = next_status(s)
      assert %{reload: %{state: :loaded, batch: 1, fanout: 1, modules: [M]}} = st
      assert Mirror.get(:runtime_status) == st
      # the notice still goes out too
      assert_receive {^s, {:notice, %{source: :reload}}}

      DynideReload.Notices.broadcast({:tests, :failed, %{files: 1, failures: 2, ms: 9}})
      assert %{reload: %{batch: 1}, tests: %{result: :failed, failures: 2}} = next_status(s)

      assert_receive {^s,
                      {:notice, %{level: :warning, text: "tests failed: 2 failures, not loaded"}}}

      DynideReload.Notices.broadcast({:tests, :running, %{files: 1}})
      assert %{tests: %{result: :running}} = next_status(s)
      refute_receive {^s, {:notice, _}}, 50

      DynideReload.Notices.broadcast({:tests, :none, %{files: 0, failures: 0, ms: 0}})
      assert %{tests: nil} = next_status(s)
      refute_receive {^s, {:notice, _}}, 50
    end

    test "a handoff sets the handoff entry, kind from Handoff.Link.adopt_reason/0, and expires" do
      s = fake_session()
      :ok = Link.put_adopted_for_test([])
      on_exit(fn -> if p = GenServer.whereis(Link), do: GenServer.stop(p) end)
      assert Link.adopt_reason() == :graceful

      Notice.broadcast({:handoff, %{phase: :adopted, gen: 2, panes: [1, 2]}})
      st = next_status(s)
      assert %{phase: :adopted, kind: :graceful, gen: 2, panes: 2} = st.handoff
      assert Mirror.get(:runtime_status) == st

      # the :expire tick after 30 s: simulate by ageing the entry
      :sys.replace_state(ReloadNotices, fn state ->
        put_in(state.status.handoff.at, state.status.handoff.at - 30_000)
      end)

      send(ReloadNotices, :expire)
      assert next_status(s).handoff == nil
    end

    test "sessions receive the status in their scene" do
      c = client()
      DynideReload.Notices.broadcast({:loaded, 3, [A, B]})
      assert_receive {^c, {:notice, _}}, 500
      wait_reload(c, "r3 2m")
    end

    test "the promotion sync shows once; a newer reload survives a registry restart" do
      start_supervised!({SyncedStub, [A, B, C, D]})
      s = fake_session()
      restart_registry()
      assert %{reload: %{state: :synced, fanout: 4}} = next_status(s)

      DynideReload.Notices.broadcast({:loaded, 5, [A, B]})
      assert %{reload: %{state: :loaded, batch: 5}} = next_status(s)

      restart_registry()
      refute_receive {^s, {:runtime_status, _}}, 100
      assert %{reload: %{state: :loaded, batch: 5}} = :sys.get_state(ReloadNotices).status
    end

    test "the newest batch seeds the status on subscribe, over the sync" do
      batch = %DynideReload.Batch{id: 7, modules: [A, B]}
      start_supervised!({SyncedStub, {[C], [batch]}})
      s = fake_session()
      restart_registry()
      assert %{reload: %{state: :loaded, batch: 7, fanout: 2}} = next_status(s)
    end

    test "a rolled back newest batch seeds :rolled_back" do
      batch = %DynideReload.Batch{id: 8, modules: [A], rolled_back: true}
      start_supervised!({SyncedStub, {[], [batch]}})
      s = fake_session()
      restart_registry()
      st = next_status(s)
      assert %{reload: %{state: :rolled_back, batch: 8, fanout: 1, reason: "earlier"}} = st
      text = inspect(RuntimeStatus.nodes(st, 200))
      assert text =~ "r8 rolled back: earlier"
      refute text =~ "manual"
    end

    test "an existing reload entry is not overwritten on re-subscribe" do
      s = fake_session()
      DynideReload.Notices.broadcast({:loaded, 5, [A]})
      assert %{reload: %{batch: 5}} = next_status(s)
      start_supervised!({SyncedStub, {[], [%DynideReload.Batch{id: 9, modules: [B]}]}})
      restart_registry()
      refute_receive {^s, {:runtime_status, _}}, 100
      assert %{reload: %{state: :loaded, batch: 5}} = :sys.get_state(ReloadNotices).status
    end

    test "a handoff entry seeded from the mirror still expires" do
      at = System.monotonic_time(:millisecond) - 31_000
      st = %{RuntimeStatus.new() | handoff: %{phase: :begin, kind: nil, gen: 1, panes: 0, at: at}}
      Mirror.put(:runtime_status, st)
      {:ok, pid} = GenServer.start(ReloadNotices, nil)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert :sys.get_state(pid).status == st
      # the tick init armed, fired early (the entry is 31 s old)
      send(pid, :expire)
      assert :sys.get_state(pid).status.handoff == nil
    end

    test "a state from before the status (a bare monitor ref) converts on code_change" do
      ref = make_ref()

      assert {:ok, %ReloadNotices{ref: ^ref, status: %{reload: nil}}} =
               ReloadNotices.code_change(nil, ref, nil)

      assert {:ok, %ReloadNotices{ref: nil}} = ReloadNotices.code_change(nil, nil, nil)
    end
  end

  # stop and restart the reload registry, then wait for the bridge to re-subscribe
  defp restart_registry do
    stop_supervised!(DynideReload.Notices)
    start_supervised!(DynideReload.Notices)
    send(ReloadNotices, :subscribe)
    wait_subscribed(50)
  end

  defp wait_subscribed(0), do: flunk("ReloadNotices did not re-subscribe")

  defp wait_subscribed(n) do
    if Registry.keys(DynideReload.Notices, Process.whereis(ReloadNotices)) == [] do
      Process.sleep(10)
      wait_subscribed(n - 1)
    else
      :sys.get_state(ReloadNotices)
    end
  end

  defp wait_reload(c, text) do
    assert_receive {^c, {:scene, s}}, 500
    status = Enum.find(s.chrome.children, &(&1.id == :status))

    case Enum.find(status.children, &(&1.id == :reload)) do
      %{text: ^text} -> :ok
      _ -> wait_reload(c, text)
    end
  end
end
