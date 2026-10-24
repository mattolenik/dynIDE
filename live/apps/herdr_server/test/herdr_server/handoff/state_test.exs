defmodule HerdrServer.Handoff.StateTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Handoff.State

  @state %{
    v: 1,
    id: 7,
    os_pid: 123,
    cols: 80,
    rows: 24,
    cell_px: {8, 16},
    max_scrollback: 1000,
    hidden: false,
    title: "t",
    pwd: nil,
    exited: nil,
    pending_input: "ls\n",
    vt: <<1, 2, 3>>,
    taken_at: 1
  }

  test "encode/decode round-trips" do
    assert @state |> State.encode() |> State.decode() == {:ok, @state}
  end

  test "wrong version is :error" do
    assert %{@state | v: 2} |> State.encode() |> State.decode() == :error
    assert State.decode(:erlang.term_to_binary(:not_a_map)) == :error
    assert State.decode("garbage") == :error
  end

  test "unsafe atoms are :error" do
    name = "herdr_state_test_fresh_#{System.unique_integer([:positive])}"
    # SMALL_ATOM_UTF8_EXT for an atom that does not exist yet
    assert State.decode(<<131, 119, byte_size(name), name::binary>>) == :error
  end
end
