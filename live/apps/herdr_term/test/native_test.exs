defmodule HerdrTerm.NativeTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Native.Tty

  test "the nif loads and open reports a missing path" do
    assert {:error, reason} = Tty.open(%{path: "/nonexistent"})
    assert is_binary(reason)
  end
end
