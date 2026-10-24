defmodule HerdrServer.Kernel.NativeContractTest do
  use ExUnit.Case, async: true

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
end
