defmodule HerdrServer.Native.StallTest do
  # Exit criterion: `mode/2` called from a normal scheduler while a pane floods
  # with a 100 MiB `cat` never blocks for 1 ms or more.
  use ExUnit.Case, async: false

  alias HerdrServer.Native.{Keeper, Vt}

  @moduletag :stall
  @moduletag timeout: 300_000

  @bytes 100 * 1024 * 1024
  @cap 5000

  setup do
    path = Path.join(System.tmp_dir!(), "herdr_stall_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)

    # 80-byte lines (79 columns plus newline), numbered.
    lines = div(@bytes, 80)

    1..lines
    |> Stream.map(fn n ->
      String.pad_leading(Integer.to_string(n), 8, "0") <> " " <> String.duplicate("x", 70) <> "\n"
    end)
    |> Stream.chunk_every(4096)
    |> Enum.into(File.stream!(path))

    assert File.stat!(path).size == @bytes
    %{path: path}
  end

  test "mode/2 never blocks 1ms during a 100MiB cat", %{path: path} do
    t0 = System.monotonic_time(:millisecond)

    {:ok, id} =
      Keeper.open(%{
        cmd: "/bin/sh",
        args: ["-c", "cat " <> path],
        env: [],
        cwd: nil,
        cols: 80,
        rows: 24,
        max_scrollback: 1000,
        subscriber: self()
      })

    {:ok, %{vt: vt}} = Keeper.lookup(id)
    # Histogram in 1us buckets (index 1..@cap, last bucket = overflow), so the
    # measuring loop does not allocate. 1: stale count, 2: max, 3: damages.
    hist = :atomics.new(@cap, signed: false)
    misc = :atomics.new(3, signed: false)

    status = loop(vt, id, hist, misc)
    wall = System.monotonic_time(:millisecond) - t0

    count = Enum.reduce(1..@cap, 0, fn i, acc -> acc + :atomics.get(hist, i) end)
    max_us = :atomics.get(misc, 2)
    pct = fn p -> percentile(hist, count, p) end

    IO.puts(
      "STALL count=#{count} p50_us=#{pct.(0.5)} p99_us=#{pct.(0.99)} p999_us=#{pct.(0.999)} " <>
        "max_us=#{max_us} stale_frac=#{Float.round(:atomics.get(misc, 1) / max(count, 1), 4)} " <>
        "cat_wall_ms=#{wall} damages=#{:atomics.get(misc, 3)}"
    )

    assert status == 0
    assert max_us < 1000
    Keeper.close(id)
  end

  defp loop(vt, id, hist, misc) do
    t = :erlang.monotonic_time(:microsecond)
    r = Vt.mode(vt, :bracketed_paste)
    d = :erlang.monotonic_time(:microsecond) - t

    :atomics.add(hist, min(d, @cap - 1) + 1, 1)
    if d > :atomics.get(misc, 2), do: :atomics.put(misc, 2, d)
    if is_tuple(r), do: :atomics.add(misc, 1, 1)

    case drain(vt, id, misc) do
      {:exit, status} -> status
      :cont -> loop(vt, id, hist, misc)
    end
  end

  defp drain(vt, id, misc) do
    receive do
      {:damage, ^id, _} ->
        :atomics.add(misc, 3, 1)
        Vt.dirty_rows(vt)
        drain(vt, id, misc)

      {:exit, ^id, status} ->
        {:exit, status}

      _other ->
        drain(vt, id, misc)
    after
      0 -> :cont
    end
  end

  defp percentile(hist, count, p) do
    target = ceil(count * p)

    Enum.reduce_while(1..@cap, 0, fn i, acc ->
      acc = acc + :atomics.get(hist, i)
      if acc >= target, do: {:halt, i - 1}, else: {:cont, acc}
    end)
  end
end
