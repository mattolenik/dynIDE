defmodule DynideServer.Kernel.NativeContractTest do
  use ExUnit.Case, async: false

  # Native.Vt and Native.Pty declare their behaviours (the compiler checks them);
  # Native.Keeper does not (adding @impl to M1's GenServer is not a one-line change).
  for {behaviour, native} <- [
        {DynideServer.Kernel.Vt, DynideServer.Native.Vt},
        {DynideServer.Kernel.Pty, DynideServer.Native.Pty},
        {DynideServer.Kernel.Keeper, DynideServer.Native.Keeper}
      ] do
    test "#{inspect(native)} exports every #{inspect(behaviour)} callback" do
      Code.ensure_loaded!(unquote(native))

      missing =
        for {f, a} <- unquote(behaviour).behaviour_info(:callbacks),
            not function_exported?(unquote(native), f, a),
            do: {f, a}

      assert missing == []
    end
  end

  describe "persistence facts" do
    alias DynideServer.Native.{Pty, Vt}

    test "Pty.cwd/1 reports the child's directory and follows cd" do
      {:ok, vt} = Vt.new(80, 24, 1000)
      dir = Path.join(System.tmp_dir!(), "herdr-cwd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, pty, _} = Pty.spawn(vt, 1, "/bin/sh", [], [{"ENV", ""}], dir, 80, 24)
      real = dir |> Path.expand() |> resolve()
      assert wait(fn -> Pty.cwd(pty) == real end)
      :ok = Pty.write(pty, "cd /\n")
      assert wait(fn -> Pty.cwd(pty) == "/" end)
      Pty.kill(pty, :kill)
    end

    test "Vt.tail_ansi/2 returns VT rows, \"\" for 0, :alt_screen on the alt screen" do
      {:ok, vt} = Vt.new(20, 5, 10_000)
      assert Vt.tail_ansi(vt, 3) == ""
      Vt.feed(vt, Enum.map_join(1..30, "\r\n", &"l#{&1}"))
      tail = Vt.tail_ansi(vt, 2)
      assert tail =~ "l29" and tail =~ "l30" and not (tail =~ "l28")
      Vt.feed(vt, "\e[31mred\e[0m")
      assert Vt.tail_ansi(vt, 1) =~ "\e["
      assert Vt.tail_ansi(vt, 0) == ""
      Vt.feed(vt, "\e[?1049h")
      assert Vt.tail_ansi(vt, 2) == :alt_screen
    end

    # macOS /var -> /private/var: compare against the OS's resolved path
    defp resolve(path) do
      case System.cmd("/bin/sh", ["-c", "cd \"$1\" && pwd -P", "_", path]) do
        {out, 0} -> String.trim(out)
        _ -> path
      end
    end

    defp wait(f, deadline \\ System.monotonic_time(:millisecond) + 2000) do
      cond do
        f.() -> true
        System.monotonic_time(:millisecond) > deadline -> false
        true -> Process.sleep(20) && wait(f, deadline)
      end
    end
  end

  describe "Kernel.load/0" do
    setup do
      prev = Application.fetch_env!(:dynide_server, :kernel)
      on_exit(fn -> Application.put_env(:dynide_server, :kernel, prev) end)
      {:ok, prev: prev}
    end

    test "raises when the kernel config is missing or incomplete", %{prev: prev} do
      Application.delete_env(:dynide_server, :kernel)
      assert_raise RuntimeError, ~r/:kernel is not set/, &DynideServer.Kernel.load/0
      Application.put_env(:dynide_server, :kernel, Keyword.delete(prev, :pty))
      assert_raise RuntimeError, ~r/no :pty module/, &DynideServer.Kernel.load/0
      assert DynideServer.Kernel.pty() == prev[:pty]
    end
  end
end
