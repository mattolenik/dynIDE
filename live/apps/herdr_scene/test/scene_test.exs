defmodule HerdrScene.SceneTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Overlay}

  defp errors(scene) do
    assert {:error, msgs} = Scene.validate(scene)
    Enum.join(msgs, "\n")
  end

  test "valid scene" do
    assert Scene.validate(HerdrScene.SceneSample.build()) == :ok
  end

  test "roles and tokens" do
    assert :status in Scene.roles()
    assert :accent in Scene.tokens()
  end

  test "pane rect outside size" do
    s = HerdrScene.SceneSample.build()
    bad = List.update_at(s.panes, 1, &%{&1 | rect: %{x: 70, y: 0, w: 20, h: 5}})
    assert errors(%{s | panes: bad}) =~ "panes[1].rect: outside scene size"
  end

  test "duplicate pane id" do
    s = HerdrScene.SceneSample.build()
    bad = List.update_at(s.panes, 1, &%{&1 | id: 1, rows: {:ref, 1, 0}})
    assert errors(%{s | panes: bad}) =~ "panes[1].id: duplicate"
  end

  test "focus pane absent" do
    s = HerdrScene.SceneSample.build()
    assert errors(%{s | focus: %{pane: 99, chrome: nil}}) =~ "focus.pane: no pane 99"
  end

  test "ref id must match pane id" do
    s = HerdrScene.SceneSample.build()
    bad = List.update_at(s.panes, 0, &%{&1 | rows: {:ref, 2, 0}})
    assert errors(%{s | panes: bad}) =~ "panes[0].rows: ref id 2 does not match pane 1"
  end

  test "bad role, token, text" do
    s = HerdrScene.SceneSample.build()
    kid = fn n -> %{s | chrome: %{s.chrome | children: [n]}} end

    assert errors(kid.(%Node{role: :banana, id: :a})) =~ "chrome.children[0].role"
    assert errors(kid.(%Node{role: :text, id: :a, token: :red})) =~ "chrome.children[0].token"
    assert errors(kid.(%Node{role: :text, id: :a, text: 123})) =~ "chrome.children[0].text"
  end

  test "props are open" do
    s = HerdrScene.SceneSample.build()
    n = %Node{role: :text, id: :a, props: %{glyph: "x", anything: [1]}}
    assert Scene.validate(%{s | chrome: %{s.chrome | children: [n]}}) == :ok
  end

  test "duplicate sibling ids and node rect outside size" do
    s = HerdrScene.SceneSample.build()
    a = %Node{role: :text, id: :a}
    r = %Node{role: :text, id: :b, rect: %{x: 0, y: 0, w: 81, h: 1}}
    msg = errors(%{s | chrome: %{s.chrome | children: [a, a, r]}})
    assert msg =~ "chrome.children[1].id: duplicate"
    assert msg =~ "chrome.children[2].rect: outside scene size"
  end

  test "focus chrome path" do
    s = HerdrScene.SceneSample.build()
    assert errors(%{s | focus: %{pane: nil, chrome: [:nope]}}) =~ "focus.chrome"
    assert Scene.validate(%{s | focus: %{pane: nil, chrome: [:status, :mode]}}) == :ok
  end

  test "overlay args and cursor" do
    s = HerdrScene.SceneSample.build()
    o = %Overlay{kind: :scrollbar, args: %{total: 1}}
    bad = List.update_at(s.panes, 1, &%{&1 | overlays: [o]})
    assert errors(%{s | panes: bad}) =~ "panes[1].overlays[0]"
    assert errors(%{s | cursor: %{x: 0, y: 0, shape: :blob}}) =~ "cursor"
  end

  test "non scene" do
    assert {:error, [_]} = Scene.validate(:nope)
  end

  test "Node.find" do
    s = HerdrScene.SceneSample.build()
    assert %Node{id: :mode} = Node.find(s.chrome, [:status, :mode])
    assert Node.find(s.chrome, [:status, :zzz]) == nil
    assert Node.find(s.chrome, []) == s.chrome
  end
end
