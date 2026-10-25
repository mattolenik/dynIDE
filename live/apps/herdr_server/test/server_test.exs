defmodule HerdrServer.ServerTest.Boom do
  @moduledoc false
  def boom(_app), do: raise("boom")
end

defmodule HerdrServer.ServerTest.Capture do
  @moduledoc false
  # a test-only modal kind that captures keys (Task 8's keybind capture sets `capture`)
  @behaviour HerdrServer.App.Modal.Kind
  alias HerdrServer.App.Modal

  def open(app), do: {Modal.push(app, %{kind: __MODULE__, capture: true, got: []}), []}

  @impl true
  def key(m, {:key, %{key: k, mods: mods}}, _app), do: {:keep, %{m | got: m.got ++ [{k, mods}]}}

  @impl true
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(_m, _app, size),
    do: %HerdrScene.Scene.Node{
      role: :modal,
      rect: HerdrServer.View.Modal.panel(size, 20, 6),
      props: %{kind: :capture}
    }

  @impl true
  def ignores_escape?(_m), do: true
end

defmodule HerdrServer.ServerTest do
  # Fake in-VM clients speak the protocol against the running herdr_server app.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.{Cell, Event, Protocol, Scene}
  alias HerdrServer.App.Store
  alias HerdrServer.Handoff.Notice
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.{Input, Rows}

  import ExUnit.CaptureLog

  setup do
    reset()
    on_exit(&reset/0)
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

    Store.reset()
  end

  # A fake client: attaches, then relays every message to the test as {client, msg}.
  defp client(size \\ %{cols: 80, rows: 24}, transport \\ :ref, kind \\ :term) do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: kind,
          transport: transport,
          size: size,
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, self(), GenServer.call(Protocol.endpoint(), {:attach, info})})
        relay(parent)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, ^pid, reply}
    assert Protocol.validate_attach_reply(reply) == :ok
    {:ok, session, %{rows: {Rows, :fetch, []}}} = reply
    {pid, session}
  end

  defp relay(parent) do
    receive do
      msg -> send(parent, {self(), msg})
    end

    relay(parent)
  end

  defp input(session, c, seq, ev), do: send(session, {:input, c, seq, ev})

  defp scene(c) do
    assert_receive {^c, {:scene, s}}, 500
    assert Scene.validate(s) == :ok
    s
  end

  # Waits for a scene matching `fun`, skipping intermediate ones.
  defp scene_until(c, fun) do
    s = scene(c)
    if fun.(s), do: s, else: scene_until(c, fun)
  end

  defp text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))

  defp vt(id) do
    {:ok, %{vt: vt}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    vt
  end

  defp pty(id) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    pty
  end

  defp flush(c) do
    receive do
      {^c, _} -> flush(c)
    after
      50 -> :ok
    end
  end

  defp vt_size(id) do
    st = :sys.get_state(vt(id))
    {st.cols, st.rows}
  end

  defp fast, do: :persistent_term.get(Protocol.fast_path_key())

  # the client's {:input_mode, mode} for input `seq`, asserted to arrive before its ack
  defp mode_before_ack(c, seq) do
    receive do
      {^c, {:input_mode, mode}} ->
        assert Protocol.validate_server_msg({:input_mode, mode}) == :ok
        assert_receive {^c, {:ack, ^seq}}
        mode

      {^c, {:ack, ^seq}} ->
        flunk("ack #{seq} before {:input_mode, _}")
    after
      500 -> flunk("no {:input_mode, _}")
    end
  end

  defp mode_text(scene), do: Scene.Node.find(scene.chrome, [:status, :mode]).text

  test "prefix mode is per client: B types while A is in prefix mode" do
    {a, sa} = client()
    scene(a)
    {b, sb} = client()
    scene(b)
    panes = Map.keys(Store.snapshot().session.panes)

    input(sa, a, 1, Event.key("b", [:ctrl]))
    assert mode_before_ack(a, 1) == :prefix
    assert mode_text(scene_until(a, &(mode_text(&1) == "PREFIX"))) == "PREFIX"

    # B's "x" goes through B's session fast path to the pane; nothing is closed
    input(sb, b, 1, Event.key("x"))
    assert_receive {^b, {:ack, 1}}
    refute_received {^b, {:input_mode, _}}
    assert eventually(fn -> Fake.Vt.read_text(vt(1), {:rows, 0..0}) == "x" end)
    assert Map.keys(Store.snapshot().session.panes) == panes
    assert mode_text(:sys.get_state(sb).last_scene) == "TERMINAL"
    assert mode_text(:sys.get_state(sa).last_scene) == "PREFIX"

    # A's "x" on the only pane asks first (the workspace would go); Enter closes it once
    # and a fresh one replaces it
    input(sa, a, 2, Event.key("x"))
    assert mode_before_ack(a, 2) == :terminal
    assert [%{kind: :confirm}] = Store.snapshot().focus.modal
    input(sa, a, 3, Event.key(:enter))
    assert_receive {^a, {:ack, 3}}
    assert Map.keys(Store.snapshot().session.panes) == [2]
    assert mode_text(:sys.get_state(sa).last_scene) == "TERMINAL"
  end

  test "attach, type, split" do
    {c, s} = client()
    assert %Scene{panes: [%{id: 1, rows: {:ref, 1, _}}]} = scene(c)

    input(s, c, 1, Event.key("x"))
    assert_receive {^c, {:ack, 1}}
    assert_receive {^c, {:damage, 1, _}}, 500
    Process.sleep(20)
    {_gen, rows, _cursor} = Rows.fetch(1)
    assert text(elem(rows, 0)) =~ ~r/^x/

    assert fast().passthrough == true
    assert fast().write == {HerdrServer.Pane.Input, :key, [1]}
    input(s, c, 2, Event.key("b", [:ctrl]))
    assert mode_before_ack(c, 2) == :prefix
    # the global record carries no mode: other clients keep their fast path
    assert fast().passthrough == true
    input(s, c, 3, Event.key("v"))
    assert_receive {^c, {:ack, 3}}
    assert %Scene{panes: [_, _]} = scene_until(c, &(length(&1.panes) == 2))
    assert fast().passthrough == true
  end

  test "a restarted pane server resubscribes and repaints in full" do
    {c, _s} = client()
    scene(c)
    flush(c)
    [{pid, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    Process.exit(pid, :kill)
    assert_receive {^c, {:damage, 1, _}}, 100
    {_gen, rows, _cursor} = Rows.fetch(1)
    assert tuple_size(rows) == 22
    assert [{new, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert new != pid
  end

  test "two clients get their own rects; the latest active one drives pty size" do
    {c1, s1pid} = client()
    s1 = scene(c1)
    {c2, s2} = client(%{cols: 120, rows: 40})
    sc2 = scene(c2)
    assert hd(s1.panes).rect != hd(sc2.panes).rect
    assert hd(sc2.panes).rect == %{x: 26, y: 1, w: 94, h: 38}

    input(s1pid, c1, 1, {:focus, true})
    assert_receive {^c1, {:ack, 1}}
    assert vt_size(1) == {54, 22}

    input(s2, c2, 1, {:focus, true})
    assert_receive {^c2, {:ack, 1}}
    assert vt_size(1) == {94, 38}
  end

  test "presses take the session fast path, consumed releases are swallowed per client" do
    {c, s} = client()
    scene(c)
    assert fast().passthrough
    store = Process.whereis(Store)
    :sys.suspend(store)
    input(s, c, 1, Event.key("q"))
    assert_receive {^c, {:ack, 1}}, 500
    :sys.resume(store)
    Process.sleep(20)
    assert Fake.Vt.read_text(vt(1), {:rows, 0..0}) == "q"

    # "v" press is consumed by the prefix; its release is swallowed by this session
    input(s, c, 2, Event.key("b", [:ctrl]))
    input(s, c, 3, Event.key("v"))
    assert_receive {^c, {:ack, 3}}
    assert "v" in :sys.get_state(s).swallow
    assert fast().passthrough
    input(s, c, 4, Event.key("v", [], event: :release))
    assert_receive {^c, {:ack, 4}}
    refute "v" in :sys.get_state(s).swallow
  end

  test "detach stops the session cleanly" do
    {c, s} = client()
    scene(c)
    ref = Process.monitor(s)
    send(s, {:detach})
    assert_receive {^c, {:detached, :requested}}
    assert_receive {:DOWN, ^ref, :process, ^s, :normal}
    assert Process.alive?(c)
  end

  test "the detach binding (prefix q) detaches only the client that pressed it" do
    {c, s} = client()
    scene(c)
    {c2, s2} = client()
    scene(c2)
    ref = Process.monitor(s)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("q"))
    assert_receive {^c, {:detached, :requested}}
    assert Protocol.validate_server_msg({:detached, :requested}) == :ok
    assert_receive {:DOWN, ^ref, :process, ^s, :normal}
    refute_receive {^c2, {:detached, _}}, 50
    assert Process.alive?(s2)
  end

  test "inline clients get full rows and cursors in scenes, and rows on damage" do
    {c, s} = client(%{cols: 80, rows: 24}, :inline)
    # the scene cursor is in screen cells: the pane starts right of the sidebar, under the tabs
    assert %Scene{panes: [%{rows: {:inline, rows}, cursor: %{x: 0}}], cursor: %{x: 26, y: 1}} =
             scene(c)

    assert length(rows) == 22
    flush(c)

    # the cursor moves: the scene is re-pushed with the new rows and cursor
    input(s, c, 1, Event.key("y"))
    assert %Scene{panes: [%{rows: {:inline, rows}}], cursor: %{x: 27, y: 1}} = scene(c)
    assert text(rows |> Map.new() |> Map.fetch!(0)) =~ ~r/^y/

    # cursor unchanged: only rows
    flush(c)
    Fake.Vt.force_full(vt(1))
    Fake.Pty.output(pty(1), "")
    assert_receive {^c, {:rows, 1, _, rows}}, 500
    assert length(rows) == 22
    assert Protocol.validate_server_msg({:rows, 1, 0, rows}) == :ok
  end

  test "ref scenes carry no cursors; damage does not re-push the scene" do
    {c, s} = client()
    assert %Scene{panes: [%{cursor: nil}], cursor: nil} = scene(c)
    flush(c)
    input(s, c, 1, Event.key("y"))
    assert_receive {^c, {:damage, 1, _}}, 500
    refute_receive {^c, {:scene, _}}, 50
    assert {_gen, _rows, %{x: 1, y: 0}} = Rows.fetch(1)
  end

  # splits pane 1, waits for the debounced mirror write
  defp two_panes(c, s) do
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    scene_until(c, &(length(&1.panes) == 2))
    Process.sleep(50)
  end

  defp split(c, s) do
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    scene_until(c, &(length(&1.panes) == 2))
    Process.sleep(50)
  end

  defp kill_store do
    old = Process.whereis(Store)
    Process.exit(old, :kill)
    assert eventually(fn -> Process.whereis(Store) not in [nil, old] end)
  end

  test "a Store restart adopts the mirrored app; sessions survive with a full scene" do
    {c, s} = client()
    {c2, s2} = client(%{cols: 100, rows: 30})
    two_panes(c, s)
    flush(c)
    flush(c2)
    old = Store.snapshot()
    kids = Rows.kernel_ids()
    panes = Enum.map([1, 2], &Registry.lookup(HerdrServer.Pane.Registry, &1))

    kill_store()

    assert %Scene{panes: [_, _]} = scene(c)
    assert %Scene{panes: [_, _]} = scene(c2)
    assert Process.alive?(s) and Process.alive?(s2)
    new = Store.snapshot()
    assert new.session == old.session
    assert new.focus == old.focus
    assert Rows.kernel_ids() == kids
    assert Enum.map([1, 2], &Registry.lookup(HerdrServer.Pane.Registry, &1)) == panes
    assert length(Fake.Keeper.ids()) == 2

    # the adopted app takes input, and the re-subscribed sessions see its changes
    input(s, c, 3, Event.key("b", [:ctrl]))
    input(s, c, 4, Event.key("v"))
    assert %Scene{panes: [_, _, _]} = scene_until(c2, &(length(&1.panes) == 3))
  end

  test "a Store restart shows panes the mirror's active tab holds though their servers are hidden" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("c"))
    # the new tab's name prompt: keep the suggested name
    input(s, c, 21, Event.key(:enter))
    scene_until(c, &match?([%{id: 2}], &1.panes))
    [{p1, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert :sys.get_state(p1).hidden
    Process.sleep(50)

    # the switch back to tab 1 reached the mirror, but the Store died before hiding
    # tab 2's pane and showing pane 1
    session = HerdrServer.Mirror.get({:app, :session})
    [ws] = session.workspaces
    HerdrServer.Mirror.put({:app, :session}, %{session | workspaces: [%{ws | active_tab: 1}]})
    focus = HerdrServer.Mirror.get({:app, :focus})
    HerdrServer.Mirror.put({:app, :focus}, %{focus | pane: 1})

    # a supervised stop and restart: does not count towards the restart intensity
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)

    assert eventually(fn -> not :sys.get_state(p1).hidden end)
    assert_receive {^c, {:damage, 1, _}}, 1000
    [{p2, _}] = Registry.lookup(HerdrServer.Pane.Registry, 2)
    assert eventually(fn -> :sys.get_state(p2).hidden end)
  end

  test "a Store restart drops panes whose kernel id is gone and closes unmapped kernels" do
    {c, s} = client()
    two_panes(c, s)
    kid = Rows.kernel_id(2)
    :ets.delete(:herdr_pane_kernel, 2)

    kill_store()

    assert %Scene{panes: [%{id: 1}]} = scene_until(c, &(length(&1.panes) == 1))
    assert Map.keys(Store.snapshot().session.panes) == [1]
    assert Fake.Keeper.lookup(kid) == :error
    assert [_] = Fake.Keeper.ids()
    assert eventually(fn -> Registry.lookup(HerdrServer.Pane.Registry, 2) == [] end)
  end

  defp tab_ids(app, name) do
    ws = hd(app.session.workspaces)
    HerdrServer.Layout.pane_ids(Enum.find(ws.tabs, &(&1.name == name)).layout)
  end

  # nothing orphaned: every keeper pane is mapped to a pane of the app, and back
  defp consistent!(app) do
    mapped = Rows.kernel_ids()
    assert Enum.sort(Fake.Keeper.ids()) == Enum.sort(Enum.map(mapped, &elem(&1, 1)))
    assert Enum.sort(Enum.map(mapped, &elem(&1, 0))) == Enum.sort(Map.keys(app.session.panes))

    for id <- Map.keys(app.session.panes),
        do: assert(eventually(fn -> Registry.lookup(HerdrServer.Pane.Registry, id) != [] end))
  end

  test "a Store restart adopts a mapped pane the mirror lost into a scratch tab" do
    {c, s} = client()
    assert_receive {^c, {:scene, _}}, 500
    Process.sleep(50)
    lost = Map.new([:session, :focus], &{&1, HerdrServer.Mirror.get({:app, &1})})
    split(c, s)
    [{pane2, _}] = Registry.lookup(HerdrServer.Pane.Registry, 2)

    # as if the last app write before a kill never reached the mirror (the Store does
    # not trap exits: no flush on stop); a supervised stop and restart does not count
    # towards the supervisor's restart intensity
    for {k, v} <- lost, do: HerdrServer.Mirror.put({:app, k}, v)
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)

    app = Store.snapshot()
    assert tab_ids(app, "1") == [1]
    assert tab_ids(app, "scratch") == [2]
    assert app.session.next_id == 3 and app.focus.pane == 1
    assert Registry.lookup(HerdrServer.Pane.Registry, 2) == [{pane2, nil}]
    consistent!(app)
  end

  # stands in for HerdrReload.Server: blames batch 7 for every failure
  defp fake_reload(last) do
    pid = spawn(fn -> fake_reload_loop(last) end)
    Process.register(pid, :p5_fake_reload)
    Application.put_env(:herdr_server, :reload_server, :p5_fake_reload)

    on_exit(fn ->
      Application.delete_env(:herdr_server, :reload_server)
      Process.exit(pid, :kill)
    end)
  end

  defp fake_reload_loop(last) do
    receive do
      {:"$gen_call", from, {:fail, _, _, _}} -> GenServer.reply(from, {:rolled_back, 7})
      {:"$gen_call", from, :last_rolled_back} -> GenServer.reply(from, last)
    end

    fake_reload_loop(last)
  end

  defp boom_on_z do
    :sys.replace_state(Process.whereis(Store), fn st ->
      put_in(st.app.ui.keybinds.prefix_binds[{"z", []}], {HerdrServer.ServerTest.Boom, :boom, []})
    end)
  end

  test "a repeat Actions failure restores state_at_load and adopts panes spawned since" do
    {c, s} = client()
    assert_receive {^c, {:scene, _}}, 500
    Process.sleep(50)
    at_load = HerdrServer.Mirror.app()
    split(c, s)
    fake_reload({:ok, 7, at_load})
    boom_on_z()
    gens = Map.new(Store.snapshot().session.panes, fn {id, m} -> {id, m.layout_gen} end)

    input(s, c, 3, Event.key("b", [:ctrl]))
    input(s, c, 4, Event.key("z"))

    assert_receive {^c,
                    {:notice,
                     %{
                       level: :warning,
                       text: "state restored to batch 7; actions since were lost"
                     }}},
                   500

    assert %Scene{panes: [%{id: 1}]} = scene_until(c, &(length(&1.panes) == 1))
    app = Store.snapshot()
    assert app.ui == at_load.ui
    assert tab_ids(app, "1") == [1]
    assert tab_ids(app, "scratch") == [2]
    assert app.focus.pane == 1
    consistent!(app)
    # a ref client never sees a layout_gen go back (it would skip a re-fetch)
    # (pane 1 is back to its full rect, so it needs a gen it never had)
    assert app.session.panes[1].layout_gen > gens[1]
    assert app.session.panes[2].layout_gen >= gens[2]

    # the restored app takes input
    input(s, c, 5, Event.key("b", [:ctrl]))
    input(s, c, 6, Event.key("v"))
    assert %Scene{panes: [_, _]} = scene_until(c, &(length(&1.panes) == 2))
    assert Map.has_key?(Store.snapshot().session.panes, 3)
  end

  test "a restore after a request's repeat failure tells the requester it failed" do
    {c, _s} = client()
    assert_receive {^c, {:scene, _}}, 500
    Process.sleep(50)
    fake_reload({:ok, 7, HerdrServer.Mirror.app()})

    # the test process is not a Store subscriber (an API connection is not either)
    assert {:ok, _, _} = Store.request({HerdrServer.ServerTest.Boom, :boom, []})
    assert_received {:notice, %{level: :error, text: "action failed: " <> _}}
    # the subscribed session gets the restore warning as before
    assert_receive {^c, {:notice, %{level: :warning, text: "state restored to batch 7" <> _}}},
                   500
  end

  test "session guarded calls attribute to the configured reload server" do
    {c, s} = client()
    scene(c)
    fake_reload(:none)
    :sys.replace_state(s, &%{&1 | keybinds: %{broken: true}})
    :erlang.trace_pattern({HerdrServer.Client.Keys, :resolve, 3}, true, [:local])
    :erlang.trace(s, true, [:call])
    input(s, c, 1, Event.key("q"))
    assert_receive {^c, {:notice, %{level: :error, text: "keys failed: " <> _}}}, 500
    :erlang.trace(s, false, [:call])
    # the fake blames batch 7, so the guard re-runs once: two calls
    assert_received {:trace, ^s, :call, {HerdrServer.Client.Keys, :resolve, _}}
    assert_received {:trace, ^s, :call, {HerdrServer.Client.Keys, :resolve, _}}
  end

  test "a restore never reuses a pane id spawned and closed since the load" do
    {c, s} = client()
    assert_receive {^c, {:scene, _}}, 500
    Process.sleep(50)
    at_load = HerdrServer.Mirror.app()
    split(c, s)
    input(s, c, 3, Event.key("b", [:ctrl]))
    input(s, c, 4, Event.key("x"))
    scene_until(c, &(length(&1.panes) == 1))
    assert Store.snapshot().session.next_id == 3
    fake_reload({:ok, 7, at_load})
    boom_on_z()

    input(s, c, 5, Event.key("b", [:ctrl]))
    input(s, c, 6, Event.key("z"))
    assert_receive {^c, {:notice, %{level: :warning, text: "state restored" <> _}}}, 500
    assert Store.snapshot().session.next_id == 3
  end

  test "a repeat Actions failure with no state to restore discards the event" do
    {c, s} = client()
    two_panes(c, s)
    fake_reload(:none)
    boom_on_z()
    before = Store.snapshot()
    input(s, c, 3, Event.key("b", [:ctrl]))
    input(s, c, 4, Event.key("z"))
    assert_receive {^c, {:notice, %{level: :error, text: "action failed: " <> _}}}, 500
    assert_receive {^c, {:ack, 4}}
    assert Store.snapshot().session == before.session
  end

  test "a restarted pane server of a hidden pane starts hidden" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("c"))
    # the new tab's name prompt: keep the suggested name
    input(s, c, 21, Event.key(:enter))
    scene_until(c, &match?([%{id: 2}], &1.panes))
    [{pid, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert :sys.get_state(pid).hidden
    Process.exit(pid, :kill)

    assert eventually(fn ->
             match?([{p, _}] when p != pid, Registry.lookup(HerdrServer.Pane.Registry, 1))
           end)

    [{new, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert :sys.get_state(new).hidden
  end

  test "the mirror owner survives stray calls, casts, messages and reloads of its module" do
    mirror = Process.whereis(HerdrServer.Mirror)
    tables = Enum.map([:herdr_pane_rows, :herdr_pane_kernel, :herdr_mirror], &:ets.whereis/1)
    HerdrServer.Mirror.put(:probe, 1)

    catch_exit(GenServer.call(HerdrServer.Mirror, :bogus, 50))
    GenServer.cast(HerdrServer.Mirror, :bogus)
    send(HerdrServer.Mirror, :bogus)
    catch_exit(:sys.get_state(HerdrServer.Mirror, 50))

    # two reloads purge the first version: a process running it would be killed
    {mod, bin, file} = :code.get_object_code(HerdrServer.Mirror)
    for _ <- 1..2, do: {:module, ^mod} = :code.load_binary(mod, file, bin)
    Process.sleep(20)

    assert Process.whereis(HerdrServer.Mirror) == mirror

    assert Enum.map([:herdr_pane_rows, :herdr_pane_kernel, :herdr_mirror], &:ets.whereis/1) ==
             tables

    assert :ets.info(:herdr_pane_rows, :owner) == mirror
    assert HerdrServer.Mirror.get(:probe) == 1
    HerdrServer.Mirror.delete(:probe)
  end

  test "a session whose new Store dies while it re-subscribes detaches its client" do
    {c, s} = client()
    scene(c)
    ref = Process.monitor(s)
    sup = HerdrServer.Supervisor
    :sys.suspend(sup)

    try do
      fake = spawn(fn -> receive do: ({:"$gen_call", _, {:subscribe, _}} -> exit(:boom)) end)
      old = Process.whereis(Store)
      Process.exit(old, :kill)
      assert eventually(fn -> Process.whereis(Store) == nil end)
      Process.register(fake, Store)
      assert_receive {^c, {:detached, :store_restart}}, 1000
      assert_receive {:DOWN, ^ref, :process, ^s, :normal}, 500
    after
      :sys.resume(sup)
    end

    assert eventually(fn -> is_pid(Process.whereis(Store)) end)
  end

  test "a detach deletes the client's mirror entry" do
    {c, s} = client()
    scene(c)
    HerdrServer.Mirror.put({:client, c}, %{viewports: %{}, hover: nil})
    ref = Process.monitor(s)
    send(s, {:detach})
    assert_receive {:DOWN, ^ref, :process, ^s, :normal}, 500
    assert HerdrServer.Mirror.client(c) == nil
  end

  test "Store mirror writes are debounced: one write per changed sub-struct" do
    {c, _s} = client()
    scene(c)
    Process.sleep(50)
    store = Process.whereis(Store)
    :erlang.trace_pattern({HerdrServer.Mirror, :put, 2}, true, [:local])
    :erlang.trace(store, true, [:call])
    for n <- 1..10, do: Store.event_async({:pane_title, 1, "t#{n}"})
    Process.sleep(60)
    :erlang.trace(store, false, [:call])

    keys = collect_puts([])
    assert keys == [{:app, :session}]
    assert HerdrServer.Mirror.app().session.panes[1].title == "t10"
  end

  defp collect_puts(acc) do
    receive do
      {:trace, _, :call, {HerdrServer.Mirror, :put, [k, _]}} -> collect_puts([k | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a re-attaching client pid gets its mirrored presentation state; it goes with the client" do
    parent = self()
    HerdrServer.Mirror.put({:client, parent}, %{viewports: %{1 => 3}, hover: {1, 2}})

    info = %{
      kind: :term,
      transport: :ref,
      size: %{cols: 80, rows: 24},
      cell_px: nil,
      caps: %{},
      client: parent
    }

    {:ok, session, _} = GenServer.call(Protocol.endpoint(), {:attach, info})
    st = :sys.get_state(session)
    assert st.viewports == %{1 => 3}
    assert st.hover == {1, 2}

    pid = spawn(fn -> receive do: (:go -> :ok) end)
    HerdrServer.Mirror.put({:client, pid}, %{viewports: %{}, hover: nil})
    {:ok, s2, _} = GenServer.call(Protocol.endpoint(), {:attach, %{info | client: pid}})
    ref = Process.monitor(s2)
    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, _, _}, 500
    assert HerdrServer.Mirror.client(pid) == nil
  end

  test "per-client input mode is mirrored and re-seeded on re-attach, and the client told" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    assert_receive {^c, {:input_mode, :prefix}}
    assert_receive {^c, {:ack, 1}}
    assert HerdrServer.Mirror.client(c).mode == :prefix

    parent = self()
    HerdrServer.Mirror.put({:client, parent}, %{HerdrServer.Mirror.client(c) | hover: nil})

    info = %{
      kind: :term,
      transport: :ref,
      size: %{cols: 80, rows: 24},
      cell_px: nil,
      caps: %{},
      client: parent
    }

    {:ok, session, _} = GenServer.call(Protocol.endpoint(), {:attach, info})
    assert :sys.get_state(session).mode == :prefix
    assert_receive {:input_mode, :prefix}
    # the re-seeded prefix applies: "v" splits
    send(session, {:input, parent, 1, Event.key("v")})
    assert_receive {:input_mode, :terminal}
    assert eventually(fn -> map_size(Store.snapshot().session.panes) == 2 end)
  end

  test "when the driving client leaves, the pty size goes back to the remaining client" do
    {c1, _s1} = client()
    scene(c1)
    assert vt_size(1) == {54, 22}
    {c2, s2} = client(%{cols: 120, rows: 40})
    scene(c2)
    assert vt_size(1) == {94, 38}
    send(s2, {:detach})
    assert eventually(fn -> vt_size(1) == {54, 22} end)
  end

  test "the driving client's cell_px reaches the pty" do
    {c, s} = client()
    scene(c)
    [{pane, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    :erlang.trace_pattern({Fake.Pty, :resize, 4}, true, [:local])
    :erlang.trace(pane, true, [:call])
    input(s, c, 1, {:resize, %{cols: 100, rows: 30, cell_px: {9, 18}}})
    assert_receive {^c, {:ack, 1}}
    assert_receive {:trace, ^pane, :call, {Fake.Pty, :resize, [_, 74, 28, {9, 18}]}}, 500
    :erlang.trace(pane, false, [:call])
  end

  test "a failed spawn warns the client and closes the pane again" do
    {c, s} = client()
    scene(c)
    before = Fake.Keeper.ids()
    :ok = Fake.Keeper.fail_next_open({:spawn, "no such shell"})
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    assert_receive {^c, {:notice, %{level: :warning, text: "could not start pane 2" <> _}}}, 500
    assert eventually(fn -> Map.keys(Store.snapshot().session.panes) == [1] end)
    assert Fake.Keeper.ids() == before
    assert Rows.kernel_id(2) == nil
  end

  test "request/1 runs a command and replies the app before and after" do
    {c, _s} = client()
    scene(c)
    mfa = {HerdrServer.App.Commands, :create_tab, [1, "x", false]}
    assert {:ok, before, after_app} = Store.request(mfa)

    assert length(hd(after_app.session.workspaces).tabs) ==
             length(hd(before.session.workspaces).tabs) + 1

    assert {:ok, ^after_app, ^after_app} =
             Store.request({HerdrServer.App.Commands, :focus_pane, [999]})
  end

  test "request/1 delivers notices to the caller" do
    {c, _s} = client()
    scene(c)
    assert {:ok, _, _} = Store.request({HerdrServer.App.Commands, :close_workspace, [1]})
    assert_receive {:notice, %{text: "cannot close the last workspace"}}, 500
  end

  test "spawned panes carry HERDR_PANE_ID" do
    {c, _s} = client()
    scene(c)
    {:ok, _, app} = Store.request({HerdrServer.App.Commands, :create_tab, [1, nil, false]})
    id = app.session.next_id - 1
    assert eventually(fn -> {"HERDR_PANE_ID", "p#{id}"} in Fake.Keeper.last_spec().env end)
  end

  test "a failing Keybinds.intercept_set keeps the Store alive and its fast path" do
    {c, s} = client()
    scene(c)
    store = Process.whereis(Store)
    :sys.replace_state(store, fn st -> put_in(st.app.ui.keybinds.prefix, :bad) end)
    before = :sys.get_state(store)
    input(s, c, 1, {:focus, true})
    assert_receive {^c, {:ack, 1}}
    after_ = :sys.get_state(store)
    assert Process.whereis(Store) == store
    assert {after_.app, after_.fast} == {before.app, before.fast}
  end

  test "pty backpressure drops input with one warning per pane per second" do
    {c, _s} = client()
    scene(c)
    :ok = Fake.Pty.set_backpressure(pty(1), true)

    log =
      capture_log(fn ->
        for k <- ~w(a b c), do: assert(Input.key(Event.key(k), 1) == {:error, :backpressure})
      end)

    assert length(String.split(log, "pane 1: input dropped")) == 2
    assert Fake.Vt.read_text(vt(1), {:rows, 0..0}) == ""
  end

  test "pastes are written in 64 KiB chunks; a mid-paste rejection notifies and closes paste mode" do
    {c, s} = client()
    scene(c)
    :ok = Fake.Vt.set_mode(vt(1), :bracketed_paste, true)
    big = :binary.copy("p", 5 * 65_536 - 10)

    input(s, c, 1, {:paste, big})
    assert_receive {^c, {:ack, 1}}
    refute_received {^c, {:notice, _}}
    writes = Fake.Pty.writes(pty(1))
    assert ["\e[200~" | _] = writes
    assert List.last(writes) == "\e[201~"

    assert writes |> Enum.slice(1..-2//1) |> Enum.map(&byte_size/1) == [
             65_536,
             65_536,
             65_536,
             65_536,
             65_526
           ]

    # start marker and two chunks go out, the third is rejected
    :ok = Fake.Pty.backpressure_once_after(pty(1), 3)
    input(s, c, 2, {:paste, big})

    assert_receive {^c,
                    {:notice, %{level: :warning, text: "paste truncated after 131072 bytes"}}},
                   500

    assert_receive {^c, {:ack, 2}}
    assert [_, _, "\e[200~", _, _, "\e[201~"] = Enum.take(Fake.Pty.writes(pty(1)), -6)
  end

  test "a hollow block cursor is stored as a block" do
    {c, _s} = client()
    scene(c)
    :ok = Fake.Vt.set_cursor_shape(vt(1), :block_hollow)
    Fake.Pty.output(pty(1), "z")
    assert eventually(fn -> match?({_, _, %{x: 1, shape: :block}}, Rows.fetch(1)) end)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "bogus attach is rejected" do
    assert {:error, [_ | _]} = GenServer.call(Protocol.endpoint(), {:attach, %{kind: :bogus}})
  end

  test "a dead client stops its session" do
    {c, s} = client()
    ref = Process.monitor(s)
    Process.exit(c, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s, _}
    assert DynamicSupervisor.which_children(HerdrServer.Client.Supervisor) == []
  end

  test "identical app changes push no duplicate scene" do
    {c, s} = client()
    scene(c)
    flush(c)
    app = Store.snapshot()
    send(s, {:app_changed, app})
    send(s, {:app_changed, app})
    refute_receive {^c, {:scene, _}}, 100
  end

  test "handoff notice is forwarded and input is held after begin" do
    {c, s} = client()
    scene(c)
    begin = {:handoff, %{phase: :begin, gen: 3, panes: [1]}}
    Notice.broadcast(begin)
    assert_receive {^c, ^begin}
    assert Protocol.validate_server_msg(begin) == :ok

    # held: a rejection notice, no ack (the client keeps it), nothing reaches the pane
    input(s, c, 5, Event.key("x"))
    input(s, c, 6, Event.key("y"))
    assert_receive {^c, {:notice, %{level: :warning}}}
    # one notice per handoff
    refute_receive {^c, {:notice, _}}, 100
    refute_received {^c, {:ack, _}}
    assert Fake.Pty.writes(pty(1)) == []

    Notice.broadcast({:handoff, %{phase: :aborted, gen: 3, panes: [1]}})
    assert_receive {^c, {:handoff, %{phase: :aborted}}}
    assert_receive {^c, {:ack, 5}}
    assert_receive {^c, {:ack, 6}}
    assert Fake.Pty.writes(pty(1)) == ["x", "y"]
  end

  test "input whose write finds the pane frozen during a handoff is held, not acked" do
    {c, s} = client()
    scene(c)
    on_exit(fn -> :persistent_term.erase(Protocol.handoff_key()) end)
    # :begin is published after this session's own check, while the write runs
    fast = :persistent_term.get(Protocol.fast_path_key())
    :persistent_term.put(Protocol.fast_path_key(), %{fast | write: {__MODULE__, :freezing, []}})
    input(s, c, 5, Event.key("x"))
    assert_receive {^c, {:notice, %{level: :warning}}}
    refute_receive {^c, {:ack, 5}}, 100

    :persistent_term.put(Protocol.fast_path_key(), fast)
    :persistent_term.put(Protocol.handoff_key(), :aborted)
    Notice.broadcast({:handoff, %{phase: :aborted, gen: 3, panes: [1]}})
    assert_receive {^c, {:ack, 5}}
    assert Fake.Pty.writes(pty(1)) == ["x"]
  end

  def freezing(_ev) do
    :persistent_term.put(Protocol.handoff_key(), :begin)
    {:error, :closed}
  end

  test "a write to an exited pane outside a handoff is dropped and acked" do
    {c, s} = client()
    scene(c)
    # the pane exited: its pty refuses writes, and no handoff is in progress
    :sys.replace_state(pty(1), &%{&1 | closed: true})
    input(s, c, 5, Event.key("x"))
    assert_receive {^c, {:ack, 5}}
    # the session is not wedged: later input is still processed and acked
    input(s, c, 6, Event.key("y"))
    assert_receive {^c, {:ack, 6}}
    refute_received {^c, {:notice, %{text: "input held" <> _}}}
    assert Fake.Pty.writes(pty(1)) == []
  end

  test "input is held from the published :begin, before the notice arrives" do
    {c, s} = client()
    scene(c)
    :persistent_term.put(Protocol.handoff_key(), :begin)
    on_exit(fn -> :persistent_term.erase(Protocol.handoff_key()) end)
    input(s, c, 5, Event.key("x"))
    assert_receive {^c, {:notice, %{level: :warning}}}
    refute_receive {^c, {:ack, 5}}, 100
    assert Fake.Pty.writes(pty(1)) == []

    :persistent_term.put(Protocol.handoff_key(), :aborted)
    Notice.broadcast({:handoff, %{phase: :aborted, gen: 3, panes: [1]}})
    assert_receive {^c, {:ack, 5}}
    assert Fake.Pty.writes(pty(1)) == ["x"]
  end

  test "server-internal and invalid events from clients are rejected but acked" do
    {c, s} = client()
    scene(c)
    input(s, c, 7, {:pane_exited, 1})
    assert_receive {^c, {:notice, %{level: :warning}}}
    assert_receive {^c, {:ack, 7}}
    input(s, c, 8, {:pane_title, 1, "pwned"})
    assert_receive {^c, {:ack, 8}}
    input(s, c, 9, {:agent_state, 1, :blocked})
    assert_receive {^c, {:ack, 9}}
    refute Map.has_key?(Store.snapshot().session.panes[1], :agent_state)
    assert Map.has_key?(Store.snapshot().session.panes, 1)
  end

  test "while the top modal captures keys they bypass Client.Keys and reach it, prefix too" do
    {c, s} = client()
    scene(c)
    :ok = Store.run({HerdrServer.ServerTest.Capture, :open, []}, %{cols: 80, rows: 24})
    scene_until(c, &Scene.Node.find(&1.chrome, [{:modal, 0}]))
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("x"))
    assert_receive {^c, {:ack, 2}}
    assert [%{got: [{"b", [:ctrl]}, {"x", []}]}] = Store.snapshot().focus.modal
    assert :sys.get_state(s).mode == :terminal
    refute_received {^c, {:input_mode, _}}
    assert Fake.Pty.writes(pty(1)) == []
  end

  @tag :tmp_dir
  test "a keybind captured in the keybinds modal republishes the fast path's intercept set",
       %{tmp_dir: dir} do
    # the capture writes [keys] to the config file: not the suite's shared one
    saved = Application.get_env(:herdr_server, :config_path)
    File.write!(Path.join(dir, "config.toml"), "onboarding = false\n")
    Application.put_env(:herdr_server, :config_path, Path.join(dir, "config.toml"))
    on_exit(fn -> Application.put_env(:herdr_server, :config_path, saved) end)
    {c, s} = client()
    scene(c)
    refute MapSet.member?(fast().intercept, {"t", [:ctrl]})
    :ok = Store.run({HerdrServer.App.Modal.Keybinds, :open, []}, %{cols: 80, rows: 24})
    scene_until(c, &Scene.Node.find(&1.chrome, [{:modal, 0}]))
    path = [{:modal, 0}, :list, {:action, "rename_tab"}]
    input(s, c, 1, {:chrome, path, {:click, %{x: 0, y: 0}}})
    assert_receive {^c, {:ack, 1}}
    assert eventually(fn -> :sys.get_state(s).capture end)
    input(s, c, 2, Event.key("t", [:ctrl]))
    assert_receive {^c, {:ack, 2}}
    assert MapSet.member?(fast().intercept, {"t", [:ctrl]})
    assert eventually(fn -> Map.has_key?(:sys.get_state(s).keybinds.direct, {"t", [:ctrl]}) end)
    assert Fake.Pty.writes(pty(1)) == []
  end

  test "prefix bindings do nothing while a modal is open; the modal still takes keys" do
    {c, s} = client()
    scene(c)
    :ok = Store.run({HerdrServer.App.Modal.Prompt, :rename_tab, []}, %{cols: 80, rows: 24})
    scene_until(c, &Scene.Node.find(&1.chrome, [{:modal, 0}]))
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    input(s, c, 3, Event.key("q"))
    assert_receive {^c, {:ack, 3}}
    input(s, c, 4, Event.key("k"))
    assert_receive {^c, {:ack, 4}}
    app = Store.snapshot()
    assert Map.keys(app.session.panes) == [1]
    assert [%{kind: :prompt, field: %{text: "1qk"}}] = app.focus.modal
  end

  test "a raising keybind yields an error notice and the store survives" do
    {c, s} = client()
    scene(c)
    store = Process.whereis(Store)

    :sys.replace_state(store, fn st ->
      put_in(st.app.ui.keybinds.prefix_binds[{"z", []}], {HerdrServer.ServerTest.Boom, :boom, []})
    end)

    # a second, larger client: its failing binding carries a driver resize that must be
    # discarded (the first client drives again through a slow-path event)
    {c2, s2} = client(%{cols: 120, rows: 40})
    scene(c2)
    input(s, c, 1, {:focus, true})
    assert_receive {^c, {:ack, 1}}
    before = :sys.get_state(store)
    assert before.driver_pid == s
    input(s2, c2, 1, Event.key("b", [:ctrl]))
    input(s2, c2, 2, Event.key("z"))
    assert_receive {^c2, {:notice, %{level: :error}}}, 500
    assert_receive {^c2, {:ack, 2}}
    assert Process.whereis(Store) == store
    # only the activity record of c2 changed; the mirror's 20 ms debounce (`flush`,
    # `mirrored`) may fire between the two reads on a slow host
    transient = &%{&1 | clients: nil, flush: nil, mirrored: nil}
    assert transient.(:sys.get_state(store)) == transient.(before)
  end

  test "View.compute's budgeted worker gets only size, transport and runtime of the client state" do
    {c, s} = client(%{cols: 80, rows: 24}, :inline)
    scene(c)
    assert %{last_scene: %Scene{}} = :sys.get_state(s)
    :erlang.trace_pattern({HerdrServer.View, :compute, 2}, true, [:local])
    :erlang.trace(:new_processes, true, [:call])

    try do
      send(s, {:app_changed, Store.snapshot()})
      assert_receive {:trace, _, :call, {HerdrServer.View, :compute, [_, st]}}, 500
      # runtime: whatever status the session holds (the mirror may carry one from a test)
      assert st == %HerdrServer.Client.State{
               size: %{cols: 80, rows: 24},
               transport: :inline,
               runtime: :sys.get_state(s).runtime
             }
    after
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace_pattern({HerdrServer.View, :compute, 2}, false, [:local])
    end
  end

  test "a failing unattributed View.compute is not re-run, notices and the session survives" do
    {c, s} = client()
    scene(c)

    log =
      capture_log(fn ->
        send(s, {:app_changed, %{}})
        assert_receive {^c, {:notice, %{level: :error, text: "view failed: ** (" <> _}}}, 500
      end)

    assert length(String.split(log, "HerdrServer.View.compute/2 failed")) == 2
    assert Process.alive?(s)
    refute_received {^c, {:scene, _}}
  end

  test "closing a pane makes stale damage harmless" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    scene_until(c, &(length(&1.panes) == 2))
    input(s, c, 3, Event.key("b", [:ctrl]))
    input(s, c, 4, Event.key("x"))
    scene_until(c, &(length(&1.panes) == 1))
    flush(c)
    send(s, {:pane_damage, 2, 99})
    send(s, {:damage, 2, 99})
    Store.event({:pane_exited, 2}, nil)
    Process.sleep(20)
    assert Process.alive?(s)
    refute_received {^c, {:damage, 2, _}}
  end

  test "an exiting pane is closed" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    scene_until(c, &(length(&1.panes) == 2))
    kid = Rows.kernel_id(2)
    Fake.Pty.kill(pty(2), :term)
    assert %Scene{panes: [%{id: 1}]} = scene_until(c, &(length(&1.panes) == 1))
    assert Fake.Keeper.lookup(kid) == :error
    assert Rows.kernel_id(2) == nil
  end

  test "inactive tabs are hidden" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("c"))
    # the new tab's name prompt: keep the suggested name
    input(s, c, 21, Event.key(:enter))
    scene_until(c, &match?([%{id: 2}], &1.panes))
    assert :sys.get_state(pty(1)).hidden
    refute :sys.get_state(pty(2)).hidden
  end

  test "panes of an inactive workspace are hidden" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("N"))
    scene_until(c, &match?([%{id: 2}], &1.panes))
    assert eventually(fn -> :sys.get_state(pty(1)).hidden end)
    refute :sys.get_state(pty(2)).hidden
  end

  test "output floods are coalesced: session queues drain" do
    {c, s} = client()
    {c2, s2} = client(%{cols: 100, rows: 30})
    scene(c)
    scene(c2)
    p = pty(1)
    for _ <- 1..10_000, do: Fake.Pty.output(p, "hello\r\n")
    # wait for the fake pty and vt to drain, then give sessions the budget
    :sys.get_state(p)
    :sys.get_state(vt(1))
    Process.sleep(200)

    for sess <- [s, s2],
        do: assert(Process.info(sess, :message_queue_len) == {:message_queue_len, 0})
  end

  # --- alerts and toasts (M13 Task 11) ---

  defp toast(scene), do: Enum.find(scene.chrome.children, &(&1.role == :toast))

  defp background_pane(c) do
    :ok = Store.run({HerdrServer.App.Actions, :new_tab, []}, %{cols: 80, rows: 24})
    scene_until(c, &match?([%{id: 2}], &1.panes))
  end

  test "a background pane's alert reaches the client and its toast focuses the pane" do
    {c, s} = client()
    scene(c)
    background_pane(c)
    Store.event_async({:agent_state, 1, :working})
    Store.event_async({:agent_state, 1, :blocked})
    assert_receive {^c, {:alert, %{level: :attention, pane: 1, sound: :request} = a}}, 1000
    assert Protocol.validate_server_msg({:alert, a}) == :ok
    t = c |> scene_until(&toast/1) |> toast()
    assert %{props: %{pane: 1, level: :attention}} = t
    input(s, c, 1, {:chrome, [t.id], {:click, %{x: t.rect.x, y: t.rect.y}}})
    assert_receive {^c, {:ack, 1}}
    scene_until(c, &(toast(&1) == nil and match?([%{id: 1}], &1.panes)))
    assert Store.snapshot().focus.pane == 1
  end

  test "the active tab suppresses toasts and the done sound unless the terminal is unfocused" do
    {c, s} = client()
    scene(c)
    Store.event_async({:agent_state, 1, :blocked})
    # the request sound is never suppressed
    assert_receive {^c, {:alert, %{title: nil, body: nil, sound: :request}}}, 1000
    Store.event_async({:agent_state, 1, :idle})
    _ = Store.snapshot()
    _ = :sys.get_state(s)
    refute_received {^c, {:alert, _}}
    assert :sys.get_state(s).toasts == []

    input(s, c, 1, {:focus, false})
    assert_receive {^c, {:ack, 1}}
    Store.event_async({:agent_state, 1, :blocked})
    assert_receive {^c, {:alert, %{title: "agent needs attention"}}}, 1000
    assert %{props: %{pane: 1}} = c |> scene_until(&toast/1) |> toast()
  end

  test "a toast expires" do
    Application.put_env(:herdr_server, :toast_ms, attention: 100, done: 100)
    on_exit(fn -> Application.delete_env(:herdr_server, :toast_ms) end)
    {c, _s} = client()
    scene(c)
    background_pane(c)
    Store.event_async({:agent_state, 1, :blocked})
    scene_until(c, &toast/1)
    scene_until(c, &(toast(&1) == nil))
  end
end
