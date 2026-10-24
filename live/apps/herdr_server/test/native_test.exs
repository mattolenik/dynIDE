defmodule HerdrServer.NativeTest do
  use ExUnit.Case, async: true

  test "hello nif constructs a ghostty terminal" do
    assert HerdrServer.Native.hello() == "herdr_kernel ghostty 80x24"
  end
end
