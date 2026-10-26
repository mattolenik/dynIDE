defmodule DynideServer.Client.Remote.OutTest do
  use ExUnit.Case, async: true

  alias DynideScene.Scene
  alias DynideServer.Client.Remote
  alias DynideServer.Client.Remote.{Carry, Out}

  defp scene(sound),
    do: %Scene{
      size: %{cols: 1, rows: 1},
      chrome: %Scene.Node{role: :root, props: %{sound: sound}},
      panes: []
    }

  test "a socket client's scene never carries the sound command or paths" do
    snd = %{enabled: true, command: "/bin/x", done_path: "/d.mp3", request_path: "/r.mp3"}
    state = Out.put(%Remote{}, {:scene, scene(snd)})
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
