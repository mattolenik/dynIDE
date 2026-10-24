defmodule HerdrScene.ProtocolTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Protocol

  @attach %{
    kind: :term,
    transport: :ref,
    size: %{cols: 80, rows: 24},
    cell_px: {8, 16},
    caps: %{},
    client: self()
  }

  test "constants" do
    assert Protocol.endpoint() == :herdr_client_endpoint
    assert Protocol.fast_path_key() == {HerdrScene.Protocol, :fast_path}
  end

  test "client messages" do
    ev = HerdrScene.Event.key("a")

    for m <- [
          {:attach, @attach},
          {:attach, %{@attach | kind: :gui, transport: :inline, cell_px: nil}},
          {:input, self(), 0, ev},
          {:detach}
        ] do
      assert Protocol.validate_client_msg(m) == :ok, inspect(m)
    end

    for m <- [
          {:attach, %{@attach | kind: :tty}},
          {:attach, %{@attach | transport: :pipe}},
          {:attach, %{@attach | size: %{cols: 0, rows: 1}}},
          {:attach, %{@attach | client: :me}},
          {:attach, Map.delete(@attach, :caps)},
          {:input, self(), -1, ev},
          {:input, :x, 0, ev},
          {:input, self(), 0, {:focus, 1}},
          {:detach, 1},
          :junk
        ] do
      assert {:error, msg} = Protocol.validate_client_msg(m), inspect(m)
      assert is_binary(msg)
    end
  end

  test "server messages" do
    scene = HerdrScene.SceneSample.build()

    for m <- [
          {:scene, scene},
          {:damage, 1, 0},
          {:rows, 1, 0, [{0, "x"}]},
          {:notice, %{level: :warning, text: "hi"}},
          {:ack, 3},
          {:handoff, %{}},
          {:detached, :requested},
          {:input_mode, :terminal},
          {:input_mode, :prefix},
          {:input_mode, :resize}
        ] do
      assert Protocol.validate_server_msg(m) == :ok, inspect(m)
    end

    for m <- [
          {:scene, %{scene | focus: %{pane: 99, chrome: nil}}},
          {:damage, 0, 0},
          {:rows, 1, 0, [{-1, "x"}]},
          {:rows, 1, 0, [{0, 5}]},
          {:notice, %{level: :fatal, text: "hi"}},
          {:ack, :x},
          {:handoff, []},
          {:detached, "requested"},
          {:input_mode, :bogus},
          {:input_mode, "prefix"},
          :junk
        ] do
      assert {:error, msg} = Protocol.validate_server_msg(m), inspect(m)
      assert is_binary(msg)
    end
  end

  test "validators are total and open" do
    for j <- [nil, 1, :x, %{}, {}, {:attach, :x}, {:input, 1}, {:scene, :x}, {:rows, :x}] do
      assert {:error, _} = Protocol.validate_client_msg(j)
      assert {:error, _} = Protocol.validate_server_msg(j)
      assert {:error, _} = Protocol.validate_attach_reply(j)
    end

    assert Protocol.validate_client_msg({:attach, Map.put(@attach, :extra, 1)}) == :ok
  end

  test "attach reply" do
    assert Protocol.validate_attach_reply({:ok, self(), %{rows: {Mod, :f, []}, extra: 1}}) == :ok
    assert Protocol.validate_attach_reply({:error, ["nope"]}) == :ok
    assert {:error, _} = Protocol.validate_attach_reply({:ok, self(), %{rows: :x}})
    assert {:error, _} = Protocol.validate_attach_reply({:ok, :pid, %{rows: {Mod, :f, []}}})
  end
end
