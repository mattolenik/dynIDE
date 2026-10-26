defmodule DynideTerm.Kernel.NativeContractTest do
  use ExUnit.Case, async: false

  for {behaviour, native} <- [
        {DynideTerm.Kernel.Tty, DynideTerm.Native.Tty},
        {DynideTerm.Kernel.Blit, DynideTerm.Native.Blit},
        {DynideTerm.Kernel.Tty, DynideTerm.Kernel.Fake.Tty},
        {DynideTerm.Kernel.Blit, DynideTerm.Kernel.Fake.Blit},
        {DynideTerm.Kernel.Desktop, DynideTerm.Native.Desktop},
        {DynideTerm.Kernel.Desktop, DynideTerm.Kernel.Fake.Desktop}
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

  describe "Kernel.load/0" do
    setup do
      prev = Application.fetch_env!(:dynide_term, :kernel)

      on_exit(fn ->
        Application.put_env(:dynide_term, :kernel, prev)
        DynideTerm.Kernel.load()
      end)

      {:ok, prev: prev}
    end

    test "test config selects the fakes, no SIGWINCH" do
      assert DynideTerm.Kernel.tty() == DynideTerm.Kernel.Fake.Tty
      assert DynideTerm.Kernel.blit() == DynideTerm.Kernel.Fake.Blit
      assert DynideTerm.Kernel.desktop() == DynideTerm.Kernel.Fake.Desktop
      refute DynideTerm.Kernel.sigwinch?()
    end

    test "raises when the kernel config is missing or incomplete", %{prev: prev} do
      Application.delete_env(:dynide_term, :kernel)
      assert_raise RuntimeError, ~r/:kernel is not set/, &DynideTerm.Kernel.load/0
      Application.put_env(:dynide_term, :kernel, Keyword.delete(prev, :blit))
      assert_raise RuntimeError, ~r/no :blit entry/, &DynideTerm.Kernel.load/0
      assert DynideTerm.Kernel.blit() == prev[:blit]
    end
  end
end
