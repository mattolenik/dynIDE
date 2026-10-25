defmodule HerdrServer.Native.KeeperTest do
  use ExUnit.Case, async: false

  alias HerdrScene.Cell
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

  defp text(row), do: row |> Cell.decode_row() |> Enum.map_join(& &1.glyph)

  defp wait_text(vt, s, deadline) do
    cond do
      Vt.read_text(vt, :viewport) =~ s -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_text(vt, s, deadline)
    end
  end

  defp saw_k?(vt, deadline) do
    {_, rows} = Vt.dirty_rows(vt)

    cond do
      Enum.any?(rows, fn {_, r} -> String.contains?(text(r), "k") end) -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && saw_k?(vt, deadline)
    end
  end

  test "open, write, damage, close, exit" do
    {:ok, id} = Keeper.open(spec(%{subscriber: self()}))
    assert {:ok, %{vt: vt, pty: pty, os_pid: os_pid}} = Keeper.lookup(id)
    assert is_integer(os_pid) and os_pid > 0
    assert id in Keeper.ids()

    assert_receive {:damage, ^id, _}, 2000
    :ok = Pty.write(pty, "echo k\n")
    assert saw_k?(vt, System.monotonic_time(:millisecond) + 2000)

    assert Keeper.close(id) == :ok
    assert Keeper.lookup(id) == :error
    assert_receive {:exit, ^id, status}, 2000
    assert status in [{:signal, 1}, 129]
    assert Keeper.close(id) == :ok
  end

  test "close escalates to SIGKILL for a child ignoring SIGHUP" do
    {:ok, id} =
      Keeper.open(
        spec(%{args: ["-c", "trap '' HUP; echo ready; exec sleep 30"], subscriber: self()})
      )

    {:ok, %{vt: vt}} = Keeper.lookup(id)
    assert wait_text(vt, "ready", System.monotonic_time(:millisecond) + 2000)
    assert Keeper.close(id) == :ok
    refute_receive {:exit, ^id, _}, 1000
    assert_receive {:exit, ^id, {:signal, 9}}, 3000
  end

  test "bad specs return errors and leave the keeper intact" do
    keeper = Process.whereis(Keeper)
    {:ok, live} = Keeper.open(spec())
    before = Keeper.ids()

    bad = [
      {Map.delete(spec(), :rows), :rows},
      {spec(%{cols: 0}), :cols},
      {spec(%{cmd: ~c"/bin/sh"}), :cmd},
      {spec(%{env: [{"A", 1}]}), :env},
      {spec(%{args: ["a" | "b"]}), :args}
    ]

    for {s, key} <- bad do
      assert Keeper.open(s) == {:error, {:invalid_spec, key}}
      # The handler validates too, for callers that bypass open/1.
      assert GenServer.call(Keeper, {:open, s}) == {:error, {:invalid_spec, key}}
    end

    assert GenServer.call(Keeper, {:open, :nope}) == {:error, {:invalid_spec, :spec}}
    # Passes validation, but the NIF raises (does not fit a usize).
    assert {:error, {:raise, _}} = Keeper.open(spec(%{max_scrollback: 2 ** 70}))

    assert Process.whereis(Keeper) == keeper
    assert Keeper.ids() == before
    assert {:ok, _} = Keeper.lookup(live)
    Keeper.close(live)
  end

  test "two opens give distinct ids" do
    {:ok, a} = Keeper.open(spec())
    {:ok, b} = Keeper.open(spec())
    assert a != b
    Keeper.close(a)
    Keeper.close(b)
  end

  test "failed spawn inserts nothing" do
    before = Keeper.ids()
    assert {:error, _} = Keeper.open(spec(%{cmd: "/nonexistent/xyz"}))
    assert Keeper.ids() == before
  end

  test "replay is fed to the new vt before the spawn; the row records cmd" do
    {:ok, id} =
      Keeper.open(spec(%{cmd: "/bin/sh", args: ["-c", "sleep 30"], replay: "hello\r\n"}))

    assert {:ok, %{vt: vt, cmd: ["/bin/sh", "-c", "sleep 30"]}} = Keeper.lookup(id)
    assert Vt.read_text(vt, :screen) =~ "hello"
    Keeper.close(id)
  end

  test "an ill-typed replay is an invalid spec; nil is no replay" do
    assert Keeper.open(spec(%{replay: 1})) == {:error, {:invalid_spec, :replay}}
    assert {:ok, id} = Keeper.open(spec(%{replay: nil}))
    Keeper.close(id)
  end

  test "lookup of unknown id is :error" do
    assert Keeper.lookup(999) == :error
  end
end
