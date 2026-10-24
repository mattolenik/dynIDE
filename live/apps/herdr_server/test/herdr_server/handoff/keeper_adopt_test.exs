defmodule HerdrServer.Handoff.KeeperAdoptTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Handoff.State
  alias HerdrServer.Native.{Keeper, Pty, Vt}

  defp spec(extra \\ %{}) do
    Map.merge(
      %{
        cmd: "/bin/sh",
        args: [],
        env: [{"PS1", "$ "}, {"ENV", ""}],
        cwd: nil,
        cols: 80,
        rows: 24,
        max_scrollback: 10_000_000,
        subscriber: nil
      },
      extra
    )
  end

  defp wait_text(vt, s, deadline \\ System.monotonic_time(:millisecond) + 3000) do
    cond do
      Vt.read_text(vt, :screen) =~ s -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_text(vt, s, deadline)
    end
  end

  defp alive?(os_pid), do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"]))

  # Hands pane `id` over as `new_id`: the original stays in the table, frozen and released.
  defp hand_over(id, new_id, change \\ & &1) do
    {:ok, row} = Keeper.lookup(id)
    blob = State.build(id, row, []) |> Map.put(:id, new_id) |> change.() |> State.encode()
    {:ok, fd} = Pty.dup_fd(row.pty)
    Pty.freeze(row.pty)
    :ok = Pty.release(row.pty)
    :ok = Keeper.adopt_entries([{"pane/#{new_id}", blob, [fd]}])
    row
  end

  test "adopt_entries keeps the child and the screen" do
    {:ok, id} = Keeper.open(spec())
    {:ok, %{vt: vt, pty: pty, os_pid: os_pid}} = Keeper.lookup(id)
    :ok = Pty.write(pty, "echo before-$((1))-hand\n")
    assert wait_text(vt, "before-1-hand")

    hand_over(id, 500)

    assert {:ok, %{os_pid: ^os_pid, vt: vt2, pty: pty2}} = Keeper.lookup(500)
    assert Vt.read_text(vt2, :screen) =~ "before-1-hand"
    :ok = Pty.write(pty2, "echo after-$((2))-hand\n")
    assert wait_text(vt2, "after-2-hand")
    assert 500 in Keeper.ids()
    assert alive?(os_pid)

    assert {:ok, 501} = Keeper.open(spec())
    Keeper.close(501)
    Keeper.close(500)
  end

  test "the blob carries the start time; a recycled pid is adopted as exited" do
    {:ok, id} = Keeper.open(spec(%{cmd: "/bin/sleep", args: ["30"]}))
    {:ok, %{os_pid: os_pid} = row} = Keeper.lookup(id)
    assert %{start_time: st} = State.build(id, row, vt: false)
    assert is_integer(st)

    hand_over(id, 410, &%{&1 | start_time: st + 1})

    assert {:ok, %{os_pid: ^os_pid, pty: pty}} = Keeper.lookup(410)
    :ok = Pty.subscribe(pty, self())
    assert_receive {:exit, 410, :unknown}, 2000
    :ok = Keeper.close(410)
    Process.sleep(200)
    assert alive?(os_pid)
    System.cmd("kill", ["-9", "#{os_pid}"])
  end

  test "a blob without start_time (older VM) adopts unchecked" do
    {:ok, id} = Keeper.open(spec(%{cmd: "/bin/sleep", args: ["30"]}))
    {:ok, %{os_pid: os_pid}} = Keeper.lookup(id)

    hand_over(id, 420, &Map.delete(&1, :start_time))

    assert {:ok, %{os_pid: ^os_pid, pty: pty}} = Keeper.lookup(420)
    :ok = Pty.subscribe(pty, self())
    :ok = Keeper.close(420)
    assert_receive {:exit, 420, :unknown}, 5000
    refute alive?(os_pid)
  end

  test "open and close are refused while frozen, and work again after thaw" do
    {:ok, id} = Keeper.open(spec(%{cmd: "/bin/sleep", args: ["30"]}))
    {:ok, %{os_pid: os_pid}} = Keeper.lookup(id)
    ids = Keeper.ids()

    :ok = Keeper.prepare()
    assert Keeper.open(spec()) == {:error, :handoff}
    assert Keeper.close(id) == {:error, :handoff}
    assert Keeper.ids() == ids
    Process.sleep(100)
    assert alive?(os_pid)

    :ok = Keeper.thaw()
    assert {:ok, id2} = Keeper.open(spec())
    :ok = Keeper.close(id2)
    :ok = Keeper.close(id)
  end

  test "a raise while handing the new pane to the broker closes it and keeps the Keeper" do
    keeper = Process.whereis(Keeper)
    ids = Keeper.ids()
    # not a link resource: the HOLD send raises ArgumentError in the Keeper
    :persistent_term.put({HerdrServer.Handoff.Link, :link}, :bogus)

    try do
      assert {:error, {:raise, _}} = Keeper.open(spec(%{cmd: "/bin/sleep", args: ["30"]}))
    after
      :persistent_term.erase({HerdrServer.Handoff.Link, :link})
    end

    assert Process.whereis(Keeper) == keeper
    assert Keeper.ids() == ids
    assert {:ok, id} = Keeper.open(spec())
    :ok = Keeper.close(id)
  end

  test "adopt with exited set never signals" do
    {:ok, id} = Keeper.open(spec(%{cmd: "/bin/sleep", args: ["30"]}))
    {:ok, %{os_pid: os_pid}} = Keeper.lookup(id)

    hand_over(id, 400, &%{&1 | exited: 0})

    assert {:ok, %{os_pid: ^os_pid, pty: pty}} = Keeper.lookup(400)
    :ok = Pty.subscribe(pty, self())
    assert_receive {:exit, 400, :unknown}, 2000
    :ok = Pty.kill(pty, :kill)
    :ok = Keeper.close(400)
    Process.sleep(200)
    assert alive?(os_pid)
    System.cmd("kill", ["-9", "#{os_pid}"])
  end
end
