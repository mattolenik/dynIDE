# Reload latency bench. Run: cd live && mix run bench/reload/reload_bench.exs
alias HerdrServer.Reload.{Notices, Server, Watcher}

defmodule ReloadBench do
  @app :toy_bench
  @dependents 20
  @independents 40

  def toy_dir do
    dir = Path.join(System.tmp_dir!(), "toy_bench_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule ToyBench.MixProject do
      use Mix.Project
      def project, do: [app: :#{@app}, version: "0.1.0", elixir: "~> 1.20", consolidate_protocols: false, deps: []]
    end
    """)

    File.write!(core_path(dir), core(0))

    for i <- 1..@dependents do
      File.write!(Path.join(dir, "lib/dep#{i}.ex"), """
      defmodule Toy.Dep#{i} do
        def get(%Toy.Core{a: a}), do: a
        def new, do: %Toy.Core{}
      end
      """)
    end

    for i <- 1..@independents,
        do: File.write!(Path.join(dir, "lib/ind#{i}.ex"), ind(i, 0))

    dir
  end

  def core_path(dir), do: Path.join(dir, "lib/core.ex")
  def ind_path(dir), do: Path.join(dir, "lib/ind1.ex")
  def ind(i, n), do: "defmodule Toy.Ind#{i} do\n  def v, do: #{n}\nend\n"

  # n extra fields: every edit changes the struct layout and the file size
  def core(n) do
    extra = Enum.map_join(1..n//1, "", &", f#{&1}: #{&1}")
    "defmodule Toy.Core do\n  defstruct a: 1#{extra}\nend\n"
  end

  def stats(label, xs) do
    s = Enum.sort(xs)
    n = length(s)
    # n is 10 or less: a p95 would be the max
    [label, "min #{Enum.min(s)}", "median #{Enum.at(s, div(n, 2))}", "max #{List.last(s)}", "ms"]
    |> Enum.join("  ")
    |> IO.puts()
  end

  def await_loaded(timeout \\ 5000) do
    receive do
      {:herdr_reload, {:loaded, _, mods}} -> length(mods)
      {:herdr_reload, {:compile_error, d}} -> raise "compile error #{inspect(d)}"
    after
      timeout -> raise "no :loaded notice in #{timeout}ms"
    end
  end

  # runs `edit.(i)` -> writes file; returns [{ms, fanout}]
  def iterate(n, write), do: for(i <- 1..n, do: (settle(); t0 = now(); write.(i); f = await_loaded(); r = {ms(t0), f}; r))

  # drain stragglers so a late event of the previous edit is not counted
  def settle do
    Process.sleep(250)
    receive do
      {:herdr_reload, _} -> settle()
    after
      0 -> :ok
    end
  end

  def now, do: System.monotonic_time(:microsecond)
  def ms(t0), do: Float.round((now() - t0) / 1000, 1)
end

Notices.subscribe()
dir = ReloadBench.toy_dir()
opts = [project_dir: dir, app: :toy_bench]
name = :reload_bench_server
{:ok, _} = Server.start_link([name: name] ++ opts)
paths = Path.join(dir, "lib")

{:ok, watcher} =
  Watcher.start_link(
    dirs: [paths],
    debounce_ms: 50,
    on_batch: fn ps -> Server.reload(name, ps) end
  )

Process.sleep(500)
# initial load of the whole toy
{:ok, _} = Server.reload(name, Path.wildcard(paths <> "/*.ex"))
flush = fn -> receive do {:herdr_reload, _} -> :ok after 0 -> :ok end end
Stream.repeatedly(flush) |> Enum.take(5)

ind = ReloadBench.ind_path(dir)
core = ReloadBench.core_path(dir)
n = 10

IO.puts("== watcher: File.write -> {:loaded,_,mods} notice (debounce 50ms) ==")
# warm-up
File.write!(ind, ReloadBench.ind(1, 1000)); ReloadBench.await_loaded()
File.write!(core, ReloadBench.core(1)); ReloadBench.await_loaded()

ra = ReloadBench.iterate(n, fn i -> File.write!(ind, ReloadBench.ind(1, i * 7)) end)
ReloadBench.stats("(a) one independent module", Enum.map(ra, &elem(&1, 0)))
IO.puts("    fan-out per iteration: #{inspect(Enum.map(ra, &elem(&1, 1)))}")

rb = ReloadBench.iterate(n, fn i -> File.write!(core, ReloadBench.core(i + 1)) end)
ReloadBench.stats("(b) add field to Toy.Core", Enum.map(rb, &elem(&1, 0)))
IO.puts("    fan-out per iteration: #{inspect(Enum.map(rb, &elem(&1, 1)))}")

GenServer.stop(watcher)
ReloadBench.settle()
IO.puts("\n== direct Server.reload (compile + load, no watcher/debounce) ==")
direct = fn label, write ->
  ts =
    for i <- 1..n do
      write.(i + 100)
      t0 = ReloadBench.now()
      {:ok, b} = Server.reload(name, [ind, core])
      {ReloadBench.ms(t0), length(b.modules)}
    end

  ReloadBench.stats(label, Enum.map(ts, &elem(&1, 0)))
  IO.puts("    fan-out per iteration: #{inspect(Enum.map(ts, &elem(&1, 1)))}")
end

direct.("(a) one independent module", fn i -> File.write!(ind, ReloadBench.ind(1, i * 7)) end)
direct.("(b) add field to Toy.Core", fn i -> File.write!(core, ReloadBench.core(i + 1)) end)

File.rm_rf!(dir)

# ---- real umbrella: default Server/Watcher started by the app in dev ----
IO.puts("\n== real umbrella: HerdrScene one-module edit via default watcher ==")
scene = Path.expand("apps/herdr_scene/lib/herdr_scene.ex")
orig = File.read!(scene)

try do
  File.write!(scene, orig <> "\n# bench warmup\n")
  Process.sleep(10)
  _ = ReloadBench.await_loaded(15_000)

  rs =
    ReloadBench.iterate(5, fn i ->
      dummy = String.duplicate("x", i)
      File.write!(scene, String.replace(orig, ~r/\nend\n\z/, "\n  def bench_dummy_#{dummy}, do: :ok\nend\n"))
    end)

  ReloadBench.stats("umbrella HerdrScene", Enum.map(rs, &elem(&1, 0)))
  IO.puts("    fan-out per iteration: #{inspect(Enum.map(rs, &elem(&1, 1)))}")
after
  File.write!(scene, orig)
  # wait for the restore's reload so beams match the source again
  ReloadBench.await_loaded(15_000)
end
