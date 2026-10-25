defmodule HerdrTerm.Remote.NoticeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Remote.Notice

  @status %Node{
    role: :status,
    id: :status,
    rect: %{x: 0, y: 23, w: 80, h: 1},
    children: [%Node{role: :text, id: :mode, text: "NORMAL"}]
  }
  @scene %Scene{
    size: %{cols: 80, rows: 24},
    chrome: %Node{role: :root, id: :root, children: [@status]}
  }
  @n %{level: :warning, text: "reconnecting in 1s"}

  defp status(scene), do: Node.find(scene.chrome, [:status])

  test "put adds a notice child first in the status, replaces it, and nil clears it" do
    s = Notice.put(@scene, @n)
    assert :ok = Scene.validate(s)

    assert [
             %Node{id: :notice, role: :text, text: "reconnecting in 1s", token: :warning},
             %{id: :mode}
           ] =
             status(s).children

    s = Notice.put(s, %{level: :error, text: "two"})
    assert [%Node{id: :notice, text: "two", token: :error}, %{id: :mode}] = status(s).children

    assert Notice.put(s, nil) == @scene
  end

  test "a scene without a :status node is unchanged" do
    bare = %Scene{size: %{cols: 80, rows: 24}}
    assert Notice.put(bare, @n) == bare
    other = %{bare | chrome: %Node{role: :root, id: :root}}
    assert Notice.put(other, @n) == other
  end

  test "blank is a valid scene with a status row" do
    s = Notice.blank(%{cols: 40, rows: 10})
    assert :ok = Scene.validate(Notice.put(s, @n))
    assert status(s).rect == %{x: 0, y: 9, w: 40, h: 1}
  end
end
