defmodule DynideServer.Native.VtSnapshotTest do
  use ExUnit.Case, async: true

  alias DynideServer.Native.Vt

  test "encode then restore keeps screen text" do
    {:ok, vt} = Vt.new(80, 24, 1_000_000)
    for n <- 1..50, do: Vt.feed(vt, "line #{n}\r\n")

    assert {:ok, vt2} = Vt.restore(Vt.encode_snapshot(vt), 1_000_000)
    assert Vt.read_text(vt2, :screen) == Vt.read_text(vt, :screen)
    assert Vt.read_text(vt2, :screen) =~ "line 50"
  end

  test "restore of garbage is an error" do
    assert {:error, msg} = Vt.restore("nope", 1_000_000)
    assert is_binary(msg)
  end
end
