defmodule HerdrReload.LocalFunsTest do
  use ExUnit.Case, async: true

  alias HerdrReload.LocalFuns

  defmodule S do
    defstruct [:field]
  end

  test "finds a local fun in nested lists and tuples" do
    assert LocalFuns.find(%{a: [1, {:x, fn -> 1 end}]}) == {:local_fun, __MODULE__, [:a, 1, 1]}
  end

  test "external funs are fine" do
    assert LocalFuns.find(%{k: &Enum.map/2}) == :ok
  end

  test "struct field path" do
    assert LocalFuns.find(%S{field: fn -> 1 end}) == {:local_fun, __MODULE__, [:field]}
  end

  test "nested map key path" do
    assert LocalFuns.find(%{a: %{"b" => fn -> 1 end}}) == {:local_fun, __MODULE__, [:a, "b"]}
  end

  test "improper list" do
    assert LocalFuns.find([1 | 2]) == :ok
  end
end
