defmodule HerdrServer.Handoff.SnapshotterTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Handoff.{Link, Snapshotter, State}
  alias HerdrServer.Native.{Keeper, Pty, Vt}
  alias HerdrServer.Native.Link, as: NLink

  setup do
    path = "/tmp/hs-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    {:ok, link} = NLink.connect(path, self())
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    :persistent_term.put({Link, :link}, link)
    Application.put_env(:herdr_server, HerdrServer.Handoff, snapshot_ms: 60_000)

    on_exit(fn ->
      Application.put_env(:herdr_server, HerdrServer.Handoff, snapshot_ms: 1000)
      :persistent_term.erase({Link, :link})
      NLink.close(link)
      :gen_tcp.close(l)
      File.rm(path)
    end)

    start_supervised!(Snapshotter)
    %{peer: peer}
  end

  # UPDATEs of one tick, by key. Drained while the tick runs: a big pane left over
  # from another test can fill the socket.
  defp tick(peer) do
    t = Task.async(fn -> Snapshotter.tick() && Snapshotter.stats() end)
    drain(peer, t, %{})
  end

  defp drain(peer, t, acc) do
    case :gen_tcp.recv(peer, 6, 50) do
      {:ok, <<len::32, kind, _>>} ->
        {:ok, body} = :gen_tcp.recv(peer, len - 2, 5000)
        {key, blob} = NLink.parse_key(body)
        drain(peer, t, if(kind == 0x03, do: Map.put(acc, key, blob), else: acc))

      {:error, :timeout} ->
        if Task.yield(t, 0), do: acc, else: drain(peer, t, acc)
    end
  end

  test "only changed panes are sent", %{peer: peer} do
    spec = %{
      cmd: "/bin/sh",
      args: [],
      env: [{"PS1", "$ "}, {"ENV", ""}],
      cwd: nil,
      cols: 80,
      rows: 24,
      max_scrollback: 1000,
      subscriber: nil
    }

    {:ok, id} = Keeper.open(spec)
    {:ok, %{vt: vt, pty: pty}} = Keeper.lookup(id)
    key = "pane/#{id}"
    Process.sleep(200)

    assert {:ok, %{id: ^id, vt: snap}} = State.decode(Map.fetch!(tick(peer), key))
    assert is_binary(snap)
    refute Map.has_key?(tick(peer), key)

    :ok = Pty.write(pty, "echo snap-$((5))\n")
    assert wait_text(vt, "snap-5")
    assert Map.has_key?(tick(peer), key)
    assert %{last_bytes: b} = Snapshotter.stats()
    assert b > 0
    Keeper.close(id)
  end

  test "resume resends every pane (an aborted handoff left final states behind)", %{peer: peer} do
    spec = %{
      cmd: "/bin/sh",
      args: [],
      env: [{"PS1", "$ "}, {"ENV", ""}],
      cwd: nil,
      cols: 80,
      rows: 24,
      max_scrollback: 1000,
      subscriber: nil
    }

    {:ok, id} = Keeper.open(spec)
    key = "pane/#{id}"
    Process.sleep(200)
    assert Map.has_key?(tick(peer), key)
    refute Map.has_key?(tick(peer), key)
    :ok = Snapshotter.pause()
    :ok = Snapshotter.resume()
    assert Map.has_key?(tick(peer), key)
    Keeper.close(id)
  end

  defp wait_text(vt, s, deadline \\ System.monotonic_time(:millisecond) + 3000) do
    cond do
      Vt.read_text(vt, :screen) =~ s -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_text(vt, s, deadline)
    end
  end
end
