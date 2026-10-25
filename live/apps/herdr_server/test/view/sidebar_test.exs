defmodule HerdrServer.View.SidebarTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Node
  alias HerdrServer.Client.State
  alias HerdrServer.View
  alias HerdrServer.View.Sidebar

  @rect %{x: 0, y: 0, w: 26, h: 39}

  defp client(c, r), do: %State{size: %{cols: c, rows: r}, transport: :ref}
  defp find(node, path), do: Node.find(node, path)
  defp items(node, section), do: find(node, [section, :list]).children
  defp badge(item), do: find(item, [{:line, 0}, :state]).props.state

  test "the sidebar is the first chrome child, with root props" do
    s = View.compute(fresh(120, 40), client(120, 40))
    assert :ok = Scene.validate(s)
    assert [%Node{role: :sidebar, id: :sidebar, rect: @rect} | _] = s.chrome.children

    assert s.chrome.props == %{
             theme: fresh(1, 1).ui.theme,
             indicators: :dots,
             mouse: true,
             sound: %{enabled: true, command: nil},
             toast: %{delivery: :herdr}
           }
  end

  test "two workspaces, the second active" do
    app = add_workspace(fresh(120, 40), "two")
    sb = Sidebar.node(app, @rect)
    assert sb.props == %{collapsed: false}
    assert find(sb, [:spaces]).text == "spaces"
    assert find(sb, [:spaces, :list]).props == %{offset: 0}

    assert [
             %Node{id: {:workspace, 1}, props: %{active: false, index: 1}},
             %Node{id: {:workspace, 2}, props: %{active: true, index: 2}} = w2
           ] = items(sb, :spaces)

    assert find(w2, [{:line, 0}, :workspace]).text == "two"
    assert %{props: %{kind: :agent_state, state: :unknown}} = find(w2, [{:line, 0}, :state])
    assert %{props: %{action: :new_workspace}, text: "new"} = find(sb, [:spaces, :new])

    assert %{props: %{action: :global_menu, attention: false}, text: "menu"} =
             find(sb, [:spaces, :menu])

    # agents: every pane in preorder, the focused one active, "terminal" until M11
    assert [%Node{id: {:pane, 1}, props: %{active: false}}, %Node{id: {:pane, 2}} = p2] =
             items(sb, :agents)

    assert p2.props.active
    assert find(p2, [{:line, 0}, :workspace]).text == "two"
    assert find(p2, [{:line, 0}, :tab]) == nil
    assert find(p2, [{:line, 1}, :agent]).text == "terminal"

    assert %{props: %{direction: :vertical, target: :sidebar_split}, rect: %{h: 1, w: 25}} =
             find(sb, [:split])

    assert %{props: %{direction: :horizontal, target: :sidebar_width}} = find(sb, [:edge])
    assert find(sb, [:edge]).rect == %{x: 25, y: 0, w: 1, h: 39}
    assert %{props: %{action: :toggle_sidebar, collapsed: false}} = find(sb, [:toggle])
  end

  test "a workspace badge is its panes' highest-priority agent state" do
    app = pfx(fresh(120, 40), "v")
    app = put_in(app.session.panes[2], Map.put(app.session.panes[2], :agent_state, :working))
    assert [w] = items(Sidebar.node(app, @rect), :spaces)
    assert badge(w) == :working

    app = put_in(app.session.panes[1], Map.put(app.session.panes[1], :agent_state, :blocked))
    sb = Sidebar.node(app, @rect)
    assert badge(hd(items(sb, :spaces))) == :blocked
    assert Enum.map(items(sb, :agents), &badge/1) == [:blocked, :working]
  end

  test "an agent name, else the pane title, names the agent line; tabs show with > 1 tab" do
    app = new_tab(fresh(120, 40))
    app = put_in(app.session.panes[1], %{app.session.panes[1] | title: "vim"})
    app = put_in(app.session.panes[2], Map.put(app.session.panes[2], :agent, "claude"))
    [a1, a2] = items(Sidebar.node(app, @rect), :agents)
    assert find(a1, [{:line, 1}, :agent]).text == "vim"
    assert find(a2, [{:line, 1}, :agent]).text == "claude"
    assert find(a1, [{:line, 0}, :tab]).text == "1"
    assert find(a2, [{:line, 0}, :tab]).text == "2"
  end

  test "collapsed: no section text, badges kept, no split, toggle collapsed" do
    app = pfx(fresh(80, 24), "b")
    s = View.compute(app, client(80, 24))
    assert :ok = Scene.validate(s)
    sb = find(s.chrome, [:sidebar])
    assert sb.props.collapsed == true
    assert sb.rect.w == 4
    assert find(sb, [:spaces]).text == nil
    assert find(sb, [:agents]).text == nil
    assert find(sb, [:split]) == nil
    assert badge(hd(items(sb, :spaces))) == :unknown
    assert find(sb, [:toggle]).props.collapsed == true
  end

  test "no sidebar region, no sidebar node; tiny sizes validate" do
    s = View.compute(fresh(20, 5), client(20, 5))
    refute Enum.any?(s.chrome.children, &(&1.role == :sidebar))

    for {c, r} <- [{1, 1}, {30, 2}, {30, 4}, {46, 7}, {120, 40}] do
      assert :ok = Scene.validate(View.compute(fresh(c, r), client(c, r)))
    end
  end

  test "the split row stays inside the sidebar, both sections at least 3 rows" do
    for h <- 6..40 do
      sb = Sidebar.node(fresh(120, 40), %{@rect | h: h})
      y = find(sb, [:split]).rect.y
      assert y >= 3 and y <= h - 3
    end

    assert find(Sidebar.node(fresh(120, 40), %{@rect | h: 5}), [:split]) == nil
  end
end
