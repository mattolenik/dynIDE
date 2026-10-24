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
        max_scrollback: 100,
        subscriber: nil
      },
      extra
    )
  end

  defp text(row), do: row |> Cell.decode_row() |> Enum.map_join(& &1.glyph)

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

  test "lookup of unknown id is :error" do
    assert Keeper.lookup(999) == :error
  end
end
