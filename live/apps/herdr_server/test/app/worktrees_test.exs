defmodule HerdrServer.App.WorktreesTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrServer.App.{Actions, Keybinds, Modal, Worktrees}
  alias HerdrServer.App.Modal.{Confirm, Menu, Prompt}

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)
  defp press(app, key), do: Actions.apply(app, Event.key(key))
  defp ws(app), do: Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))

  test "open adds a focused auto-named workspace whose pane spawns in the checkout" do
    {app, [{:spawn, 2, %{cols: _, rows: _}, %{cwd: "/w/feat", replay: nil}}]} =
      Worktrees.open(fresh(), "/w/feat", "feat", true)

    assert %{id: 2, name: "feat", auto_name: true, cwd: "/w/feat"} = ws(app)

    {app, _} = Worktrees.open(app, "/w/b", "mine", false, false)
    assert %{name: "mine", auto_name: false} = List.last(app.session.workspaces)
    assert ws(app).id == 2
  end

  test "the new_worktree prompt emits a create effect for the active workspace's root pane" do
    {app, []} = Prompt.new_worktree(fresh())
    assert %{kind: :prompt, title: "new worktree"} = Modal.top(app)
    app = Enum.reduce(["f", "/", "x"], app, &elem(press(&2, &1), 0))
    {app, fx} = press(app, :enter)
    assert app.focus.modal == []
    assert fx == [{:worktree, :create, %{pane: 1, branch: "f/x"}}]
  end

  test "prefix+G opens the new_worktree prompt; open and remove are unbound" do
    assert Keybinds.lookup(Keybinds.default(), :prefix, {"G", []}) == {Prompt, :new_worktree, []}
    cfg = Keybinds.to_config(Keybinds.default())
    assert cfg["new_worktree"] == ["prefix+shift+g"]
    assert cfg["open_worktree"] == [] and cfg["remove_worktree"] == []
  end

  test "remove asks first, then a dirty result asks again before forcing" do
    {app, []} = Confirm.remove_worktree(fresh())
    assert %{title: "Remove worktree?", tone: :danger} = Modal.top(app)
    {app, fx} = press(app, :enter)
    assert fx == [{:worktree, :remove, %{pane: 1, force: false}}]

    {app, []} = Worktrees.done(app, {:dirty, 1})
    assert %{kind: :confirm, title: "Worktree has changes"} = Modal.top(app)
    {_app, fx} = press(app, :enter)
    assert fx == [{:worktree, :remove, %{pane: 1, force: true}}]
  end

  test "done: open, removed, error" do
    {app, [{:spawn, 2, _, %{cwd: "/w/a"}}]} = Worktrees.done(fresh(), {:open, "/w/a", "a"})
    assert ws(app).name == "a"
    {app, _} = Worktrees.open(app, "/w/a/sub", "a2", false)

    {app, fx} = Worktrees.done(app, {:removed, "/w/a"})
    assert Enum.map(app.session.workspaces, & &1.id) == [1]
    assert {:close, 2} in fx and {:close, 3} in fx
    assert {:notice, %{level: :info, text: "removed worktree /w/a"}} in fx

    assert {_, [{:notice, %{level: :warning, text: "fatal: not a git repository"}}]} =
             Worktrees.done(app, {:error, "fatal: not a git repository"})
  end

  test "the open-worktree menu opens new checkouts and focuses open ones" do
    {app, fx} = Menu.open_worktree(fresh())
    assert fx == [{:worktree, :list, %{pane: 1}}]

    {app, _} = Worktrees.open(app, "/w/a", "a", false)
    entries = [%{path: "/w/a", label: "a", branch: "a"}, %{path: "/w/b", label: "b", branch: nil}]
    {app, []} = Worktrees.done(app, {:list, entries})

    assert %{kind: :menu, items: [{0, "a (a)", focus}, {1, "b", open}]} = Modal.top(app)
    assert focus == {HerdrServer.App.Workspaces, :switch_workspace_id, [2]}
    assert open == {Worktrees, :open, ["/w/b", "b", true]}

    node = Modal.view(app, %{cols: 80, rows: 24})
    assert [{:entry, 0}, {:entry, 1}] = Enum.map(node.children, & &1.id)

    {app, [{:spawn, 3, _, %{cwd: "/w/b"}}]} = press(app, :down) |> elem(0) |> press(:enter)
    assert ws(app).name == "b"

    assert {_, [{:notice, %{level: :info}}]} = Worktrees.done(fresh(), {:list, []})
  end

  test "owner picks the deepest checkout holding a workspace's cwd" do
    cwds = [{1, "/r"}, {2, "/r/.wt/x/src"}, {3, nil}]
    paths = ["/r", "/r/.wt/x"]
    assert Worktrees.owner(cwds, paths, "/r") == 1
    assert Worktrees.owner(cwds, paths, "/r/.wt/x") == 2
    assert Worktrees.owner(cwds, paths, "/other") == nil
    refute Worktrees.under?("/rx", "/r")
  end
end
