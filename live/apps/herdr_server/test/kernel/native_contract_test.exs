defmodule HerdrServer.Kernel.NativeContractTest do
  use ExUnit.Case, async: false

  # Native.Vt and Native.Pty declare their behaviours (the compiler checks them);
  # Native.Keeper does not (adding @impl to M1's GenServer is not a one-line change).
  for {behaviour, native} <- [
        {HerdrServer.Kernel.Vt, HerdrServer.Native.Vt},
        {HerdrServer.Kernel.Pty, HerdrServer.Native.Pty},
        {HerdrServer.Kernel.Keeper, HerdrServer.Native.Keeper}
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
      prev = Application.fetch_env!(:herdr_server, :kernel)
      on_exit(fn -> Application.put_env(:herdr_server, :kernel, prev) end)
      {:ok, prev: prev}
    end

    test "raises when the kernel config is missing or incomplete", %{prev: prev} do
      Application.delete_env(:herdr_server, :kernel)
      assert_raise RuntimeError, ~r/:kernel is not set/, &HerdrServer.Kernel.load/0
      Application.put_env(:herdr_server, :kernel, Keyword.delete(prev, :pty))
      assert_raise RuntimeError, ~r/no :pty module/, &HerdrServer.Kernel.load/0
      assert HerdrServer.Kernel.pty() == prev[:pty]
    end
  end
end
