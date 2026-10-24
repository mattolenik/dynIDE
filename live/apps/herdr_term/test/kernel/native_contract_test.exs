defmodule HerdrTerm.Kernel.NativeContractTest do
  use ExUnit.Case, async: false

  for {behaviour, native} <- [
        {HerdrTerm.Kernel.Tty, HerdrTerm.Native.Tty},
        {HerdrTerm.Kernel.Blit, HerdrTerm.Native.Blit},
        {HerdrTerm.Kernel.Tty, HerdrTerm.Kernel.Fake.Tty},
        {HerdrTerm.Kernel.Blit, HerdrTerm.Kernel.Fake.Blit}
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
      prev = Application.fetch_env!(:herdr_term, :kernel)

      on_exit(fn ->
        Application.put_env(:herdr_term, :kernel, prev)
        HerdrTerm.Kernel.load()
      end)

      {:ok, prev: prev}
    end

    test "test config selects the fakes, no SIGWINCH" do
      assert HerdrTerm.Kernel.tty() == HerdrTerm.Kernel.Fake.Tty
      assert HerdrTerm.Kernel.blit() == HerdrTerm.Kernel.Fake.Blit
      refute HerdrTerm.Kernel.sigwinch?()
    end

    test "raises when the kernel config is missing or incomplete", %{prev: prev} do
      Application.delete_env(:herdr_term, :kernel)
      assert_raise RuntimeError, ~r/:kernel is not set/, &HerdrTerm.Kernel.load/0
      Application.put_env(:herdr_term, :kernel, Keyword.delete(prev, :blit))
      assert_raise RuntimeError, ~r/no :blit entry/, &HerdrTerm.Kernel.load/0
      assert HerdrTerm.Kernel.blit() == prev[:blit]
    end
  end
end
