# OS-only floor probe (M6 gate); driven by os_floor.sh.
# standalone stall probe: Process.sleep(1) overshoot + long_schedule, with 16 light workers
dur = String.to_integer(System.get_env("DUR_MS", "4000"))

collector = spawn(fn ->
  loop = fn loop, acc ->
    receive do
      {:monitor, _, kind, info} -> loop.(loop, [{kind, info[:timeout]} | acc])
      {:stop, from} -> send(from, {:mon, acc})
    end
  end
  loop.(loop, [])
end)
:erlang.system_monitor(collector, [{:long_schedule, 5}, {:long_gc, 5}])
tab = :ets.new(:t, [:public, :set])
workers = for i <- 1..16 do
  spawn(fn ->
    w = fn w ->
      receive do
        :stop -> :ok
      after 4 ->
        :ets.insert(tab, {i, List.to_tuple(for r <- 1..50, do: <<r::size(800)>>)})
        w.(w)
      end
    end
    w.(w)
  end)
end
probe = spawn(fn ->
  p = fn p, max, hist ->
    receive do
      {:stop, from} -> send(from, {:probe, max, hist})
    after 0 ->
      t0 = System.monotonic_time(:microsecond)
      Process.sleep(1)
      o = System.monotonic_time(:microsecond) - t0 - 1000
      b = cond do o < 2000 -> :lt2; o < 5000 -> :lt5; o < 10000 -> :lt10; o < 30000 -> :lt30; true -> :ge30 end
      p.(p, max(max, o), Map.update(hist, b, 1, &(&1 + 1)))
    end
  end
  p.(p, 0, %{})
end)
:msacc.start()
Process.sleep(dur)
msacc = :msacc.stats()
send(probe, {:stop, self()})
send(collector, {:stop, self()})
Enum.each(workers, &send(&1, :stop))
receive do {:probe, max, hist} -> IO.puts("probe max #{max / 1000} ms hist #{inspect(hist)}") end
receive do {:mon, acc} ->
  ls = for {:long_schedule, t} <- acc, do: t
  IO.puts("long_schedule n=#{length(ls)} max=#{Enum.max(ls, fn -> 0 end)}")
end
if System.get_env("MSACC") == "1" do
  for %{type: type, id: id, counters: c} <- msacc, type in [:scheduler] do
    tot = c |> Map.values() |> Enum.sum()
    top = c |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(3) |> Enum.map(fn {k, v} -> "#{k}=#{Float.round(100 * v / tot, 1)}%" end)
    IO.puts("#{type} #{id}: #{Enum.join(top, " ")}")
  end
end
