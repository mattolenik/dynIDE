defmodule HerdrServer.Client.Remote.OutTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Scene
  alias HerdrServer.Client.Remote
  alias HerdrServer.Client.Remote.{Carry, Out}

  defp scene(sound),
    do: %Scene{
      size: %{cols: 1, rows: 1},
      chrome: %Scene.Node{role: :root, props: %{sound: sound}},
      panes: []
    }

  test "a socket client's scene never carries the sound command" do
    state = Out.put(%Remote{}, {:scene, scene(%{enabled: true, command: "/bin/x"})})
    assert state.outbox.scene.chrome.props.sound == %{enabled: true}
  end

  test "a scene without a sound command is queued unchanged" do
    s = scene(%{enabled: false})
    assert Out.put(%Remote{}, {:scene, s}).outbox.scene == s
  end

  test "freeze applies the acks already in the mailbox, not the conn's own" do
    own = 4_611_686_018_427_387_904
    send(self(), {:ack, 5})
    send(self(), {:ack, own})
    send(self(), {:ack, 3})
    state = Carry.freeze(%Remote{acked: 1})
    assert %{acked: 5, frozen: true} = state
    assert_received {:ack, ^own}
    refute_received {:ack, _}
  end
end
