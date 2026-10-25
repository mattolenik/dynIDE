defmodule HerdrServer.Client.Remote.OutTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Scene
  alias HerdrServer.Client.Remote
  alias HerdrServer.Client.Remote.Out

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
end
