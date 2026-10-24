defmodule HerdrServer.ServerTest.Boom do
  @moduledoc false
  def boom(_app), do: raise("boom")
end

defmodule HerdrServer.ServerTest do
  # Fake in-VM clients speak the protocol against the running herdr_server app.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.{Cell, Event, Protocol, Scene}
  alias HerdrServer.App.Store
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
    assert_receive {^c, {:ack, 2}}
    assert fast().passthrough == false
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
    assert tuple_size(rows) == 23
    assert [{new, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert new != pid
  end

  test "two clients get their own rects; the latest active one drives pty size" do
    {c1, s1pid} = client()
    s1 = scene(c1)
    {c2, s2} = client(%{cols: 120, rows: 40})
    sc2 = scene(c2)
    assert hd(s1.panes).rect != hd(sc2.panes).rect
    assert hd(sc2.panes).rect == %{x: 0, y: 0, w: 120, h: 39}

    input(s1pid, c1, 1, Event.key("b", [:ctrl]))
    assert_receive {^c1, {:ack, 1}}
    assert vt_size(1) == {80, 23}

    input(s2, c2, 1, Event.key("b", [:ctrl]))
    assert_receive {^c2, {:ack, 1}}
    assert vt_size(1) == {120, 39}
  end

  test "presses take the session fast path, releases go through the store" do
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

    # "v" press is consumed by the prefix; its release must reach the Store's swallow set
    input(s, c, 2, Event.key("b", [:ctrl]))
    input(s, c, 3, Event.key("v"))
    assert_receive {^c, {:ack, 3}}
    assert "v" in Store.snapshot().focus.swallow
    assert fast().passthrough
    input(s, c, 4, Event.key("v", [], event: :release))
    assert_receive {^c, {:ack, 4}}
    refute "v" in Store.snapshot().focus.swallow
  end

  test "detach stops the session cleanly" do
    {c, s} = client()
    scene(c)
    ref = Process.monitor(s)
    send(s, {:detach})
    assert_receive {:DOWN, ^ref, :process, ^s, :normal}
    assert Process.alive?(c)
  end

  test "inline clients get full rows and cursors in scenes, and rows on damage" do
    {c, s} = client(%{cols: 80, rows: 24}, :inline)
    assert %Scene{panes: [%{rows: {:inline, rows}, cursor: %{x: 0}}], cursor: %{x: 0}} = scene(c)
    assert length(rows) == 23
    flush(c)

    # the cursor moves: the scene is re-pushed with the new rows and cursor
    input(s, c, 1, Event.key("y"))
    assert %Scene{panes: [%{rows: {:inline, rows}}], cursor: %{x: 1, y: 0}} = scene(c)
    assert text(rows |> Map.new() |> Map.fetch!(0)) =~ ~r/^y/

    # cursor unchanged: only rows
    flush(c)
    Fake.Vt.force_full(vt(1))
    Fake.Pty.output(pty(1), "")
    assert_receive {^c, {:rows, 1, _, rows}}, 500
    assert length(rows) == 23
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

  test "a Store restart stops sessions; a re-attach gets a fresh pane and no orphans" do
    {c, s} = client()
    scene(c)
    input(s, c, 1, Event.key("b", [:ctrl]))
    input(s, c, 2, Event.key("v"))
    scene_until(c, &(length(&1.panes) == 2))
    ref = Process.monitor(s)
    old = Process.whereis(Store)
    [{old_pane, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)

    log =
      capture_log(fn ->
        Process.exit(old, :kill)
        assert_receive {:DOWN, ^ref, :process, ^s, :normal}, 500
        assert eventually(fn -> Process.whereis(Store) not in [nil, old] end)
        {c2, _} = client()
        assert %Scene{panes: [%{id: 1}]} = scene(c2)
      end)

    refute log =~ "could not start"
    assert [_] = Fake.Keeper.ids()
    assert [{1, _}] = Rows.kernel_ids()
    assert [{new_pane, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert new_pane != old_pane
    assert Registry.lookup(HerdrServer.Pane.Registry, 2) == []
  end

  test "when the driving client leaves, the pty size goes back to the remaining client" do
    {c1, _s1} = client()
    scene(c1)
    assert vt_size(1) == {80, 23}
    {c2, s2} = client(%{cols: 120, rows: 40})
    scene(c2)
    assert vt_size(1) == {120, 39}
    send(s2, {:detach})
    assert eventually(fn -> vt_size(1) == {80, 23} end)
  end

  test "the driving client's cell_px reaches the pty" do
    {c, s} = client()
    scene(c)
    [{pane, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    :erlang.trace_pattern({Fake.Pty, :resize, 4}, true, [:local])
    :erlang.trace(pane, true, [:call])
    input(s, c, 1, {:resize, %{cols: 100, rows: 30, cell_px: {9, 18}}})
    assert_receive {^c, {:ack, 1}}
    assert_receive {:trace, ^pane, :call, {Fake.Pty, :resize, [_, 100, 29, {9, 18}]}}, 500
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
        for k <- ~w(a b c), do: assert(Input.key(Event.key(k), 1) == :ok)
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

  test "server-internal and invalid events from clients are rejected but acked" do
    {c, s} = client()
    scene(c)
    input(s, c, 7, {:pane_exited, 1})
    assert_receive {^c, {:notice, %{level: :warning}}}
    assert_receive {^c, {:ack, 7}}
    input(s, c, 8, {:pane_title, 1, "pwned"})
    assert_receive {^c, {:ack, 8}}
    assert Map.has_key?(Store.snapshot().session.panes, 1)
  end

  test "a raising keybind yields an error notice and the store survives" do
    {c, s} = client()
    scene(c)
    store = Process.whereis(Store)

    :sys.replace_state(store, fn st ->
      put_in(st.app.ui.keybinds.prefix_binds[{"z", []}], {HerdrServer.ServerTest.Boom, :boom, []})
    end)

    input(s, c, 1, Event.key("b", [:ctrl]))
    assert_receive {^c, {:ack, 1}}
    # a second, larger client: its failing event carries a driver resize that must be discarded
    {c2, s2} = client(%{cols: 120, rows: 40})
    scene(c2)
    input(s, c, 2, Event.key("b", [:ctrl]))
    input(s, c, 3, Event.key("b", [:ctrl]))
    assert_receive {^c, {:ack, 3}}
    before = :sys.get_state(store)
    assert before.app.focus.mode == :prefix
    input(s2, c2, 1, Event.key("z"))
    assert_receive {^c2, {:notice, %{level: :error}}}, 500
    assert_receive {^c2, {:ack, 1}}
    assert Process.whereis(Store) == store
    # only the activity record of c2 changed
    assert %{:sys.get_state(store) | clients: nil} == %{before | clients: nil}
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
    scene_until(c, &match?([%{id: 2}], &1.panes))
    assert :sys.get_state(pty(1)).hidden
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
end
