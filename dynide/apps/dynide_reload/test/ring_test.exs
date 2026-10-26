defmodule DynideReload.RingTest do
  use ExUnit.Case, async: true

  alias DynideReload.{Batch, Ring}

  defp batch(id, mods, extra \\ []), do: struct!(Batch, [id: id, modules: mods] ++ extra)

  defp ring(batches) do
    Enum.reduce(batches, Ring.new(10), fn b, r -> r |> Ring.push(b) |> elem(0) end)
  end

  test "evicts oldest beyond depth" do
    r = Ring.new(2)
    {r, []} = Ring.push(r, batch(1, [A]))
    {r, []} = Ring.push(r, batch(2, [A]))
    {r, [%Batch{id: 1}]} = Ring.push(r, batch(3, [A]))
    assert Enum.map(Ring.batches(r), & &1.id) == [3, 2]
  end

  test "get and update" do
    r = ring([batch(1, [A])])
    r = Ring.update(r, 1, &%{&1 | failures: 3})
    assert Ring.get(r, 1).failures == 3
    assert Ring.get(r, 9) == nil
  end

  describe "live?" do
    @opts [exercise_n: 3, exercise_floor_ms: 100]
    setup do: {:ok, b: batch(1, [A, B], loaded_at: 0, baseline: %{A => 10}, total_baseline: 10)}

    test("inside floor", %{b: b}, do: assert(Ring.live?(b, %{A => 99}, 99, 50, @opts)))

    test "false when floor elapsed and all exercised", %{b: b} do
      refute Ring.live?(b, %{A => 13}, 13, 200, @opts)
    end

    test "true while a counted module is short", %{b: b} do
      assert Ring.live?(b, %{A => 11, B => 50}, 13, 200, @opts)
    end

    test "true while total is short", %{b: b} do
      assert Ring.live?(b, %{A => 13}, 12, 200, @opts)
    end

    test "rolled back is never live", %{b: b} do
      refute Ring.live?(%{b | rolled_back: true}, %{}, 0, 0, @opts)
    end
  end

  describe "attribute" do
    setup do: {:ok, r: ring([batch(1, [A, B]), batch(2, [B])])}

    test "newest live batch intersecting the stack", %{r: r} do
      assert Ring.attribute(r, [B], fn _ -> true end).id == 2
      assert Ring.attribute(r, [A], fn _ -> true end).id == 1
      assert Ring.attribute(r, [C], fn _ -> true end) == nil
    end

    test "skips non-live batches", %{r: r} do
      assert Ring.attribute(r, [B], &(&1.id == 1)).id == 1
      assert Ring.attribute(r, [B], fn _ -> false end) == nil
    end
  end

  test "rollback_set is transitive and newest first" do
    r = ring([batch(1, [A]), batch(2, [B]), batch(3, [A, C]), batch(4, [C])])
    assert Enum.map(Ring.rollback_set(r, 1), & &1.id) == [4, 3, 1]
    assert Ring.rollback_set(r, 9) == []
  end

  test "rollback_set skips rolled back batches" do
    r = ring([batch(1, [A]), batch(2, [A], rolled_back: true)])
    assert Enum.map(Ring.rollback_set(r, 1), & &1.id) == [1]
  end
end
