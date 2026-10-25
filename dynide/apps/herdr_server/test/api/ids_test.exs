defmodule HerdrServer.Api.IdsTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Api.Ids

  test "formats ids" do
    assert Ids.workspace(1) == "w1"
    assert Ids.tab(1, 2) == "w1:t2"
    assert Ids.pane(3) == "p3"
  end

  test "parses and round-trips" do
    assert Ids.parse_workspace("w12") == {:ok, 12}
    assert Ids.parse_tab("w1:t2") == {:ok, {1, 2}}
    assert Ids.parse_pane("p3") == {:ok, 3}
    assert Ids.parse_pane(Ids.pane(99)) == {:ok, 99}
    assert Ids.parse_tab(Ids.tab(4, 5)) == {:ok, {4, 5}}
  end

  test "rejects anything but the exact public form" do
    for bad <- ["3", "p0", "p03", "p-1", "p+1", "P3", " p3", "p3 ", "p3\n", "w1", "", nil, 3, :p3] do
      assert Ids.parse_pane(bad) == :error, inspect(bad)
    end

    assert Ids.parse_workspace("w0") == :error
    assert Ids.parse_workspace("p1") == :error
    assert Ids.parse_tab("w1") == :error
    assert Ids.parse_tab("w1:t0") == :error
    assert Ids.parse_tab("t2") == :error
    assert Ids.parse_tab("w1:t2:x") == :error
  end
end
