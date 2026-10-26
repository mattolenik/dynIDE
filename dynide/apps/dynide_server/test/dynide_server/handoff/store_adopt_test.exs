defmodule DynideServer.Handoff.StoreAdoptTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideServer.App.Store
  alias DynideServer.Handoff.Link
  alias DynideServer.Kernel.Fake
  alias DynideServer.Native.Link, as: NLink
  alias DynideServer.Pane.Rows

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  # not a kill: the supervisor's restart intensity (3 in 5 s) is shared with other tests
  defp restart_store do
    :ok = Supervisor.terminate_child(DynideServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(DynideServer.Supervisor, Store)
  end

  test "init with an app/store entry adopts instead of closing" do
    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    app = Store.snapshot()
    [{1, kid}] = Rows.kernel_ids()
    # a keeper pane the Store never mapped (e.g. opened through ctl)
    {:ok, other} =
      Fake.Keeper.open(spec())

    # a fresh VM: no pane servers, no row cache, an app/store entry from the broker
    DynideServer.Pane.Supervisor.stop_pane(1)
    Rows.delete(1)
    blob = :erlang.term_to_binary(%{v: 1, app: app, kernel_ids: [{1, kid}]})
    :ok = Link.put_adopted_for_test([{"app/store", blob, []}])
    on_exit(fn -> if pid = Process.whereis(Link), do: GenServer.stop(pid) end)

    restart_store()
    # the config applied right after init settles the adopted pane (a layout_gen bump)
    snap = Store.snapshot()
    assert %{snap | session: %{snap.session | panes: app.session.panes}} == app
    assert Rows.kernel_ids() == [{1, kid}]
    assert [{pane, _}] = Registry.lookup(DynideServer.Pane.Registry, 1)
    assert Enum.sort(Fake.Keeper.ids()) == Enum.sort([kid, other])
    assert Link.take_adopted("app/") == []

    # the adopted app is mirrored at once: a restart in this VM restarts from the
    # mirror (M4), keeps the pane server and closes no keeper pane, not even the unmapped one
    restart_store()
    # settle resizes the adopted pane to its rect then (a layout_gen bump)
    assert Store.snapshot().session.workspaces == app.session.workspaces
    assert Rows.kernel_ids() == [{1, kid}]
    assert [{^pane, _}] = Registry.lookup(DynideServer.Pane.Registry, 1)
    assert Enum.sort(Fake.Keeper.ids()) == Enum.sort([kid, other])

    # without a mirror, a restart in the adopted VM still closes no keeper pane
    for k <- [:session, :focus, :ui], do: DynideServer.Mirror.delete({:app, k})
    restart_store()
    assert Enum.sort(Fake.Keeper.ids()) == Enum.sort([kid, other])
    # its pane servers stop (Registry unregisters asynchronously, so check the pid)
    refute Process.alive?(pane)
  end

  test "an app/store entry without session.panes adopts as an empty app" do
    {:ok, kid} = Fake.Keeper.open(spec())
    blob = :erlang.term_to_binary(%{v: 1, app: %{session: %{}}, kernel_ids: [{1, kid}]})
    :ok = Link.put_adopted_for_test([{"app/store", blob, []}])
    on_exit(fn -> if pid = Process.whereis(Link), do: GenServer.stop(pid) end)

    restart_store()
    assert Store.snapshot() == nil
    assert Fake.Keeper.ids() == [kid]
    # unclaimed: RESTORED drops it
    assert :sys.get_state(Link).rejected == ["app/store"]
  end

  defp spec,
    do: %{
      cmd: "sh",
      args: [],
      env: [],
      cwd: nil,
      cols: 10,
      rows: 5,
      max_scrollback: 0,
      subscriber: nil
    }

  test "a changed app is held under app/store" do
    path = "/tmp/hs-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    {:ok, link} = NLink.connect(path, self())
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    :persistent_term.put({Link, :link}, link)

    on_exit(fn ->
      :persistent_term.erase({Link, :link})
      NLink.close(link)
      :gen_tcp.close(l)
      File.rm(path)
    end)

    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    assert {:ok, <<len::32, 0x02, 0>>} = :gen_tcp.recv(peer, 6, 5000)
    {:ok, body} = :gen_tcp.recv(peer, len - 2, 5000)
    assert {"app/store", blob} = NLink.parse_key(body)
    app = Store.snapshot()

    assert %{v: 1, app: ^app, kernel_ids: [{1, _}]} =
             :erlang.binary_to_term(blob, [:safe])
  end
end
