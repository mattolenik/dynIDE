defmodule HerdrTerm.NativeTest do
  use ExUnit.Case, async: true

  test "hello nif returns the crate name" do
    assert HerdrTerm.Native.hello() == "herdr_term"
  end
end
