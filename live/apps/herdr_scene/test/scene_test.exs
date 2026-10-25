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

  test "m9 overlays and cursor shapes" do
    s = HerdrScene.SceneSample.build()
    put = fn o -> %{s | panes: List.update_at(s.panes, 1, &%{&1 | overlays: [o]})} end

    for o <- [
          %Overlay{kind: :copy_cursor, args: %{at: {0, 3}}},
          %Overlay{kind: :search_match, args: %{from: {0, 0}, to: {4, 0}, current: true}},
          %Overlay{kind: :search_match, args: %{from: {0, 0}, to: {4, 0}, current: false}}
        ] do
      assert Scene.validate(put.(o)) == :ok, inspect(o)
    end

    for o <- [
          %Overlay{kind: :copy_cursor, args: %{at: {-1, 0}}},
          %Overlay{kind: :search_match, args: %{from: {0, 0}, to: {4, 0}}},
          %Overlay{kind: :search_match, args: %{from: {0, 0}, to: {4, 0}, current: 1}}
        ] do
      assert errors(put.(o)) =~ "panes[1].overlays[0]", inspect(o)
    end

    assert Scene.validate(%{s | cursor: %{x: 0, y: 0, shape: :default}}) == :ok
    assert Scene.validate(%{s | cursor: %{x: 0, y: 0, shape: :bar, blinking: true}}) == :ok
    assert errors(%{s | cursor: %{x: 0, y: 0, shape: :bar, blinking: 1}}) =~ "cursor"

    pc = fn c -> %{s | panes: List.update_at(s.panes, 1, &%{&1 | cursor: c})} end
    assert Scene.validate(pc.(%{x: 0, y: 0, shape: :default, visible: true})) == :ok

    assert Scene.validate(pc.(%{x: 0, y: 0, shape: :block, visible: true, blinking: true})) ==
             :ok

    assert errors(pc.(%{x: 0, y: 0, shape: :block, visible: true, blinking: 1})) =~ "cursor"
  end

  test "pane layer defaults to base, accepts popup, rejects others" do
    s = HerdrScene.SceneSample.build()
    assert Enum.all?(s.panes, &(&1.layer == :base))
    popup = List.update_at(s.panes, 1, &%{&1 | layer: :popup})
    assert Scene.validate(%{s | panes: popup}) == :ok
    bad = List.update_at(s.panes, 1, &%{&1 | layer: :float})
    assert errors(%{s | panes: bad}) =~ "panes[1].layer: expected one of [:base, :popup]"
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

  @junk [nil, 1, :x, "s", [], [1 | 2], %{}, {}, {:a, :b}]

  test "validate is total on junk" do
    for j <- @junk, do: assert({:error, [_ | _]} = Scene.validate(j))

    s = HerdrScene.SceneSample.build()
    all_x = %Scene{size: :x, panes: :x, chrome: :x, focus: :x, cursor: :x}
    assert {:error, _} = Scene.validate(all_x)

    ok_size = %Scene{size: s.size, panes: :x, chrome: :x, focus: :x, cursor: :x}
    assert {:error, msgs} = Scene.validate(ok_size)
    assert Enum.any?(msgs, &(&1 =~ "panes: not a list"))
  end

  test "validate is total on malformed members" do
    s = HerdrScene.SceneSample.build()
    assert {:error, _} = Scene.validate(%{s | panes: [:x]})
    assert {:error, _} = Scene.validate(%{s | panes: [:x, hd(s.panes)]})

    plain = %{s | chrome: %{s.chrome | children: [%{id: :a}]}, focus: %{pane: nil, chrome: [:a]}}
    assert {:error, _} = Scene.validate(plain)

    bad_kids = %{s | chrome: %{s.chrome | children: :x}, focus: %{pane: nil, chrome: [:a]}}
    assert {:error, _} = Scene.validate(bad_kids)
    assert Node.find(bad_kids.chrome, [:a]) == nil
  end

  test "extra keys are accepted" do
    s = HerdrScene.SceneSample.build()
    pane = hd(s.panes)

    pane = %{
      pane
      | rect: Map.put(pane.rect, :z, 1),
        overlays: [%Overlay{kind: :dim, args: %{reason: :inactive, extra: 1}}]
    }

    assert Scene.validate(%{s | size: Map.put(s.size, :dpr, 2), panes: [pane | tl(s.panes)]}) ==
             :ok
  end

  test "pane requires rows" do
    assert_raise ArgumentError, fn -> struct!(HerdrScene.Scene.Pane, id: 1, rect: %{}) end
  end
end
