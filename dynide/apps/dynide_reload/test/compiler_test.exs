# a toy project compiler that raises on demand, after the Elixir compiler ran
defmodule Mix.Tasks.Compile.ToyBoom do
  @moduledoc false
  use Mix.Task.Compiler

  @impl true
  def run(_args), do: if(Process.get(:toy_boom), do: raise("boom"), else: {:noop, []})
end

defmodule DynideReload.CompilerTest do
  use DynideReload.ReloadCase, async: false

  import DynideReload.ReloadCase
  import ExUnit.CaptureIO

  alias DynideReload.Compiler

  @s "defmodule ToyC.S do\n  defstruct a: 1\nend\n"
  @u "defmodule ToyC.U do\n  def make, do: %ToyC.S{}\nend\n"

  defp v_src(n) do
    """
    defmodule ToyC.V do
      def v, do: #{n}
      def loop do
        receive do
          :stop -> :ok
          _ -> loop()
        end
      end
    end
    """
  end

  # modules are VM-global: every test uses the same names and cleans them up
  @mods [ToyC.S, ToyC.U, ToyC.V, ToyC.New]

  setup do
    on_exit(fn ->
      for m <- @mods do
        :code.purge(m)
        :code.delete(m)
        :code.purge(m)
      end
    end)
  end

  defp toy!(app, extra \\ "") do
    dir =
      toy_project!(app, %{"lib/s.ex" => @s, "lib/u.ex" => @u, "lib/v.ex" => v_src(1)}, extra)

    opts = [project_dir: dir, app: app]
    paths = for f <- ~w(s u v), do: Path.join(dir, "lib/#{f}.ex")
    {:ok, %{mtimes: mtimes}} = Compiler.compile(%{}, paths, %{}, opts)

    on_exit(fn ->
      for d <- Map.values(Compiler.ebin_dirs(opts)), do: :code.del_path(String.to_charlist(d))
    end)

    {dir, opts, mtimes}
  end

  defp path(dir, f), do: Path.join(dir, "lib/#{f}.ex")

  # dynamic call: the toy modules do not exist when this test compiles
  defp v, do: Module.concat([ToyC.V]).v()

  test "snapshot reads every toy beam" do
    {_dir, opts, _} = toy!(:toy_c_snap)
    snap = Compiler.snapshot(opts)
    assert snap |> Map.keys() |> Enum.sort() == [ToyC.S, ToyC.U, ToyC.V]
    assert Enum.all?(Map.values(snap), &is_binary/1)
  end

  test "struct field edit fans out to its users" do
    {dir, opts, mtimes} = toy!(:toy_c_fan)
    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/s.ex", "defmodule ToyC.S do\n  defstruct a: 1, b: 2\nend\n")

    assert {:ok, res} = Compiler.compile(snap, [path(dir, "s")], mtimes, opts)
    assert res.changed |> Map.keys() |> Enum.sort() == [ToyC.S, ToyC.U]
    assert res.previous[ToyC.S] == snap[ToyC.S]
    assert res.removed == []
  end

  test "same-second same-size edit is compiled" do
    {dir, opts, mtimes} = toy!(:toy_c_same)
    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, r1} = Compiler.compile(snap, [path(dir, "v")], mtimes, opts)
    assert Map.keys(r1.changed) == [ToyC.V]

    write_source!(dir, "lib/v.ex", v_src(3))

    assert {:ok, r2} =
             Compiler.compile(Compiler.snapshot(opts), [path(dir, "v")], r1.mtimes, opts)

    assert Map.keys(r2.changed) == [ToyC.V]
  end

  # a reloader that just started knows no mtimes; Mix recorded v.ex at its last compile
  for {name, offset} <- [same_second: 0, next_second: 1] do
    test "first edit after start, #{name} as the last compile, is compiled" do
      {dir, opts, compiled} = toy!(:"toy_c_first_#{unquote(name)}")
      p = path(dir, "v")
      snap = Compiler.snapshot(opts)
      seeded = Compiler.source_mtimes(opts)
      assert seeded[p] == compiled[p]

      write_source!(dir, "lib/v.ex", v_src(2))
      File.touch!(p, compiled[p] + unquote(offset))
      assert {:ok, r} = Compiler.compile(snap, [p], seeded, opts)
      assert Map.keys(r.changed) == [ToyC.V]
    end
  end

  test "compile error restores unloaded modules" do
    {dir, opts, mtimes} = toy!(:toy_c_err)
    assert v() == 1
    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/v.ex", "defmodule ToyC.V do\n  def v, do: (\nend\n")

    # the parallel compiler prints the error itself
    {res, _} = with_io(:stderr, fn -> Compiler.compile(snap, [path(dir, "v")], mtimes, opts) end)
    assert {:error, diags, _mtimes} = res
    assert Enum.any?(diags, &(&1.severity == :error))
    assert v() == 1
  end

  test "compile error restores cached modules that were never loaded" do
    {dir, opts, mtimes} = toy!(:toy_c_err_cold)
    refute :code.is_loaded(ToyC.V)
    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/v.ex", "defmodule ToyC.V do\n  def v, do: (\nend\n")

    {res, _} = with_io(:stderr, fn -> Compiler.compile(snap, [path(dir, "v")], mtimes, opts) end)
    assert {:error, _, _} = res
    assert v() == 1
  end

  test "a raising compile restores unloaded modules and re-raises" do
    {dir, opts, mtimes} = toy!(:toy_c_raise, ", compilers: Mix.compilers() ++ [:toy_boom]")
    assert v() == 1
    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/v.ex", v_src(2))
    Process.put(:toy_boom, true)

    assert_raise RuntimeError, "boom", fn ->
      Compiler.compile(snap, [path(dir, "v")], mtimes, opts)
    end

    Process.delete(:toy_boom)
    assert v() == 1
  end

  test "new module has nil previous" do
    {dir, opts, mtimes} = toy!(:toy_c_new)
    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/new.ex", "defmodule ToyC.New do\nend\n")

    assert {:ok, res} = Compiler.compile(snap, [path(dir, "new")], mtimes, opts)
    assert Map.keys(res.changed) == [ToyC.New]
    assert res.previous == %{ToyC.New => nil}
  end

  test "deleted file is removed" do
    {dir, opts, mtimes} = toy!(:toy_c_del)
    snap = Compiler.snapshot(opts)
    File.rm!(path(dir, "v"))

    assert {:ok, res} = Compiler.compile(snap, [path(dir, "v")], mtimes, opts)
    assert res.removed == [ToyC.V]
    assert res.changed == %{}
    assert res.previous == %{ToyC.V => snap[ToyC.V]}
  end

  test "pre-sweep blocks on a process running old code before mix runs" do
    {dir, opts, mtimes} = toy!(:toy_c_block)
    assert v() == 1
    pid = spawn(Module.concat([ToyC.V]), :loop, [])

    write_source!(dir, "lib/v.ex", v_src(2))
    assert {:ok, r1} = Compiler.compile(Compiler.snapshot(opts), [path(dir, "v")], mtimes, opts)
    # Mix deleted current V: the loop now runs old (gen 1) code
    assert :erlang.check_old_code(ToyC.V)

    snap = Compiler.snapshot(opts)
    write_source!(dir, "lib/v.ex", v_src(3))

    assert {:blocked, ToyC.V, [%{pid: ^pid}]} =
             Compiler.compile(snap, [path(dir, "v")], r1.mtimes, opts ++ [retries: 1])

    assert Process.alive?(pid)
    assert Compiler.snapshot(opts) == snap
    send(pid, :stop)
  end
end
