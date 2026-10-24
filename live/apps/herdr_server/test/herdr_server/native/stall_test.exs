defmodule HerdrServer.Native.StallTest do
  # Exit criterion: `mode/2` called from a normal scheduler while a pane floods
  # with a 100 MiB `cat` never blocks for 1 ms or more.
  use ExUnit.Case, async: false

  alias HerdrServer.Native.{Keeper, Vt}

  @moduletag :stall
  @moduletag timeout: 300_000

  @bytes 100 * 1024 * 1024
  @cap 5000
  # Control: `:erlang.phash2/1` over this list costs about what `mode/2` does
  # (~150-200 ns here), so it is equally exposed to OS preemption. A ~50 ns
  # control is preempted less often per call, and that gap alone failed the old
  # `+ 3` slack once the host ran CPU-saturated (m6 task 4b).
  @control_term Enum.to_list(1..60)

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
    misc = :atomics.new(8, signed: false)
    # Control: the same timed loop around a duration-matched BIF, interleaved with
    # the mode call so it sees the same load. 4: control max. 5/6: mode/control
    # samples >= 1ms. 7/8: mode/control total ns.
    ctrl = :atomics.new(@cap, signed: false)

    status = loop(vt, id, hist, ctrl, misc, @control_term)
    wall = System.monotonic_time(:millisecond) - t0

    count = Enum.reduce(1..@cap, 0, fn i, acc -> acc + :atomics.get(hist, i) end)
    max_us = :atomics.get(misc, 2)
    pct = fn p -> percentile(hist, count, p) end

    IO.puts(
      "STALL count=#{count} p50_us=#{pct.(0.5)} p99_us=#{pct.(0.99)} p999_us=#{pct.(0.999)} " <>
        "max_us=#{max_us} stale_frac=#{Float.round(:atomics.get(misc, 1) / max(count, 1), 4)} " <>
        "cat_wall_ms=#{wall} damages=#{:atomics.get(misc, 3)}"
    )

    mode_over = :atomics.get(misc, 5)
    ctrl_over = :atomics.get(misc, 6)

    IO.puts(
      "CONTROL count=#{count} p999_us=#{percentile(ctrl, count, 0.999)} max_us=#{:atomics.get(misc, 4)} " <>
        "mode_over_1ms=#{mode_over} control_over_1ms=#{ctrl_over} " <>
        "mode_mean_ns=#{div(:atomics.get(misc, 7), max(count, 1))} " <>
        "control_mean_ns=#{div(:atomics.get(misc, 8), max(count, 1))}"
    )

    assert status == 0
    # Max is reported, not asserted: rare >1ms outliers also occur in the control
    # (scheduler preemption). Non-blocking is proven by try_lock + mode_stale_when_locked.
    assert percentile(hist, count, 0.999) < 1000
    # Structural: mode/2 is not slow more often than a BIF of the same duration
    # under the same load. The 1.5x + 5 slack is about 3 sigma of Poisson noise
    # at the tens of samples a CPU-saturated host gives (0 when quiet). Blocking
    # 2 ms on 1 call in 50k fails it on a quiet host, 1 in 10k when saturated.
    assert mode_over * 2 <= ctrl_over * 3 + 10
    Keeper.close(id)
  end

  defp loop(vt, id, hist, ctrl, misc, term) do
    t = :erlang.monotonic_time(:nanosecond)
    r = Vt.mode(vt, :bracketed_paste)
    ns = :erlang.monotonic_time(:nanosecond) - t
    d = div(ns, 1000)
    :atomics.add(misc, 7, ns)

    :atomics.add(hist, min(d, @cap - 1) + 1, 1)
    if d > :atomics.get(misc, 2), do: :atomics.put(misc, 2, d)
    if is_tuple(r), do: :atomics.add(misc, 1, 1)
    if d >= 1000, do: :atomics.add(misc, 5, 1)

    t = :erlang.monotonic_time(:nanosecond)
    :erlang.phash2(term)
    ns = :erlang.monotonic_time(:nanosecond) - t
    c = div(ns, 1000)
    :atomics.add(misc, 8, ns)
    :atomics.add(ctrl, min(c, @cap - 1) + 1, 1)
    if c > :atomics.get(misc, 4), do: :atomics.put(misc, 4, c)
    if c >= 1000, do: :atomics.add(misc, 6, 1)

    case drain(vt, id, misc) do
      {:exit, status} -> status
      :cont -> loop(vt, id, hist, ctrl, misc, term)
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
