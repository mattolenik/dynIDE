defmodule HerdrServer.Handoff.StoreAdoptTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.App.Store
  alias HerdrServer.Handoff.Link
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Native.Link, as: NLink
  alias HerdrServer.Pane.Rows

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp restart_store do
    old = Process.whereis(Store)
    Process.exit(old, :kill)
    assert eventually(fn -> Process.whereis(Store) not in [nil, old] end)
  end

  test "init with an app/store entry adopts instead of closing" do
    :ok = Store.event({:resize, %{cols: 80, rows: 24, cell_px: nil}}, nil)
    app = Store.snapshot()
    [{1, kid}] = Rows.kernel_ids()
    # a keeper pane the Store never mapped (e.g. opened through ctl)
    {:ok, other} =
      Fake.Keeper.open(%{
        cmd: "sh",
        args: [],
        env: [],
        cwd: nil,
        cols: 10,
        rows: 5,
        max_scrollback: 0,
        subscriber: nil
      })

    # a fresh VM: no pane servers, no row cache, an app/store entry from the broker
    HerdrServer.Pane.Supervisor.stop_pane(1)
    Rows.delete(1)
    blob = :erlang.term_to_binary(%{v: 1, app: app, kernel_ids: [{1, kid}]})
    :ok = Link.put_adopted_for_test([{"app/store", blob, []}])
    on_exit(fn -> if pid = Process.whereis(Link), do: GenServer.stop(pid) end)

    restart_store()
    assert Store.snapshot() == app
    assert Rows.kernel_ids() == [{1, kid}]
    assert [{_pid, _}] = Registry.lookup(HerdrServer.Pane.Registry, 1)
    assert Enum.sort(Fake.Keeper.ids()) == Enum.sort([kid, other])
    assert Link.take_adopted("app/") == []
  end

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
