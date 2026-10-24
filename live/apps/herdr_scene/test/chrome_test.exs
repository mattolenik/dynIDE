defmodule HerdrScene.ChromeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Chrome, Scene}
  alias HerdrScene.Scene.Node

  defp with_kid(node) do
    s = HerdrScene.SceneSample.build()
    %{s | chrome: %{s.chrome | children: [node]}}
  end

  @rect %{x: 0, y: 0, w: 10, h: 3}

  test "vocabularies" do
    assert Chrome.region_roles() == [:status, :sidebar, :tabs, :divider, :modal, :menu, :toast]
    assert Chrome.badge_states() == [:idle, :working, :blocked, :done, :unknown]

    assert Chrome.action_kinds() ==
             [:click, :double_click, :right_click, :middle_click, :drag, :drop] ++
               [:scroll_up, :scroll_down]

    for r <- [:section, :list, :item, :badge, :input, :keycap, :menu, :toast],
        do: assert(r in Scene.roles())

    for t <- [:success, :info, :selected, :surface, :strong], do: assert(t in Scene.tokens())
    assert length(Scene.roles()) == 19
    assert length(Scene.tokens()) == 12
  end

  test "every role has a required-props entry" do
    for r <- Scene.roles(), do: assert(is_list(Chrome.required_props(r)))
  end

  test "required props per role" do
    assert Chrome.required_props(:tab) == [:index, :active]
    assert Chrome.required_props(:badge) == [:kind, :state]
    assert Chrome.required_props(:input) == [:cursor]
    assert Chrome.required_props(:keycap) == [:key, :mods]
    assert Chrome.required_props(:button) == [:action]
    assert Chrome.required_props(:modal) == [:kind]
    assert Chrome.required_props(:menu) == [:kind]
    assert Chrome.required_props(:toast) == [:level]

    for r <- [:item, :list, :section, :sidebar, :status, :tabs, :root, :text, :group, :spacer],
        do: assert(Chrome.required_props(r) == [])
  end

  test "a tab without :index is rejected" do
    tab = %Node{role: :tab, id: {:tab, 1}, text: "1", props: %{active: true}}

    assert Scene.validate(with_kid(tab)) ==
             {:error, ["chrome.children[0].props: :tab needs [:index]"]}
  end

  test "a modal without rect is rejected" do
    modal = %Node{role: :modal, id: {:modal, 0}, props: %{kind: :confirm}}

    assert Scene.validate(with_kid(modal)) ==
             {:error, ["chrome.children[0].rect: :modal is a region and needs a rect"]}

    assert Scene.validate(with_kid(%{modal | rect: @rect})) == :ok
  end

  test "a region nested below a rect-carrying ancestor needs no rect" do
    tab = %Node{role: :tab, id: {:tab, 1}, text: "1", props: %{index: 1, active: true}}
    tabs = %Node{role: :tabs, id: :tabs, children: [tab]}
    status = %Node{role: :status, id: :status, rect: %{x: 0, y: 23, w: 80, h: 1}}
    assert Scene.validate(with_kid(%{status | children: [tabs]})) == :ok

    group = %Node{role: :group, id: :g, children: [tabs]}
    assert Scene.validate(with_kid(%{status | children: [group]})) == :ok

    assert Chrome.errors("x", tabs, in_region: true) == []
    assert Chrome.errors("x", tabs) == ["x.rect: :tabs is a region and needs a rect"]
  end

  test "a top-level region without a rect-carrying ancestor is rejected" do
    modal = %Node{role: :modal, id: {:modal, 0}, props: %{kind: :confirm}}
    group = %Node{role: :group, id: :g, children: [modal]}

    assert Scene.validate(with_kid(group)) ==
             {:error,
              ["chrome.children[0].children[0].rect: :modal is a region and needs a rect"]}
  end

  test "badge state outside the vocabulary is rejected" do
    badge = %Node{role: :badge, id: :state, props: %{kind: :agent_state, state: :sleepy}}
    assert {:error, [msg]} = Scene.validate(with_kid(badge))
    assert msg =~ "chrome.children[0].props.state"

    for s <- Chrome.badge_states(),
        do: assert(Scene.validate(with_kid(put_in(badge.props.state, s))) == :ok)

    other = %Node{role: :badge, id: :b, props: %{kind: :count, state: 3}}
    assert Scene.validate(with_kid(other)) == :ok
  end

  test "input cursor past the text is rejected" do
    input = %Node{role: :input, id: :input, text: "abc", props: %{cursor: 4}}
    assert {:error, [msg]} = Scene.validate(with_kid(input))
    assert msg =~ "chrome.children[0].props.cursor"

    assert Scene.validate(with_kid(put_in(input.props.cursor, 3))) == :ok
    assert {:error, [_]} = Scene.validate(with_kid(put_in(input.props.cursor, -1)))
    assert Scene.validate(with_kid(%{input | text: nil, props: %{cursor: 0}})) == :ok
  end

  test "divider takes a path or a target" do
    d = %Node{role: :divider, id: :d, rect: @rect, props: %{direction: :vertical, path: []}}
    assert Scene.validate(with_kid(d)) == :ok

    t = %{d | props: %{direction: :horizontal, target: :sidebar_width}}
    assert Scene.validate(with_kid(t)) == :ok

    assert Scene.validate(with_kid(%{d | props: %{direction: :vertical}})) ==
             {:error, ["chrome.children[0].props: :divider needs [:path]"]}

    assert Scene.validate(with_kid(%{d | props: %{path: []}})) ==
             {:error, ["chrome.children[0].props: :divider needs [:direction]"]}
  end

  test "errors are path-named and extra props are allowed" do
    button = %Node{role: :button, id: :new, props: %{}}
    assert Chrome.errors("x.y", button) == ["x.y.props: :button needs [:action]"]
    assert Chrome.errors("x", %{button | props: %{action: :new, extra: 1}}) == []
    assert Chrome.errors("x", %{button | props: :nope}) == []
    assert Chrome.errors("x", :not_a_node) == []
  end

  test "nested nodes are checked" do
    keycap = %Node{role: :keycap, id: :k, props: %{key: "b"}}
    status = %Node{role: :status, id: :status, rect: %{x: 0, y: 23, w: 80, h: 1}}
    s = with_kid(%{status | children: [keycap]})

    assert Scene.validate(s) ==
             {:error, ["chrome.children[0].children[0].props: :keycap needs [:mods]"]}
  end
end
