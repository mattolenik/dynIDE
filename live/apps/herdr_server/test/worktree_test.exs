defmodule HerdrServer.WorktreeTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Worktree

  @moduletag :git
  @moduletag skip: if(System.find_executable("git"), do: false, else: "git not installed")

  @git ["-c", "user.email=t@t", "-c", "user.name=t"]

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | @git] ++ args, stderr_to_stdout: true)
    out
  end

  setup do
    base = Path.join(System.tmp_dir!(), "wt-#{System.unique_integer([:positive])}")
    root = Path.join(base, "proj")
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["commit", "-q", "--allow-empty", "-m", "init"])
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, root: root}
  end

  test "slug" do
    assert Worktree.slug("feature/x y") == "feature-x-y"
    assert Worktree.slug("issue/137 Worktree Spaces") == "issue-137-worktree-spaces"
    assert Worktree.slug("a//b..c") == "a-b-c"
    assert Worktree.slug("--é--") == "worktree"
    assert Worktree.slug("") == "worktree"
  end

  test "default_path expands ~" do
    assert Worktree.default_path(nil, "r", "a/b") ==
             Path.join([System.user_home!(), ".herdr-live/worktrees", "r", "a-b"])

    assert Worktree.default_path("/d", "r", "a/b") == "/d/r/a-b"
  end

  test "parse porcelain" do
    out = """
    worktree /a
    HEAD abc
    branch refs/heads/main

    worktree /b
    HEAD def
    detached
    prunable gitdir file points to non-existent location

    worktree /c.git
    bare
    """

    assert [
             %{path: "/a", branch: "main", head: "abc", detached?: false},
             %{path: "/b", branch: nil, detached?: true, prunable?: true},
             %{path: "/c.git", bare?: true}
           ] = Worktree.parse(out)
  end

  test "repo and non-repo", %{base: base, root: root} do
    assert {:ok, %{name: "proj", root: r, common: c}} = Worktree.repo(root)
    assert Path.basename(r) == "proj"
    assert Path.basename(c) == ".git"
    plain = Path.join(base, "plain")
    File.mkdir_p!(plain)
    assert {:error, _} = Worktree.repo(plain)
  end

  test "add, list, remove", %{base: base, root: root} do
    assert {:ok, [%{branch: "main", bare?: false}]} = Worktree.list(root)

    path = Worktree.default_path(base, "proj", "feature/x-y")
    assert String.ends_with?(path, "feature-x-y")
    assert :ok = Worktree.add(root, path, "feature/x-y", nil)
    assert {:ok, wts} = Worktree.list(root)

    assert Enum.any?(
             wts,
             &(&1.branch == "feature/x-y" and String.ends_with?(&1.path, "feature-x-y"))
           )

    File.write!(Path.join(path, "dirty.txt"), "x")
    assert {:error, :dirty} = Worktree.remove(root, path, false)
    assert :ok = Worktree.remove(root, path, true)
    refute File.exists?(path)
    assert git!(root, ["branch", "--list", "feature/x-y"]) =~ "feature/x-y"

    # existing branch is checked out rather than recreated
    assert :ok = Worktree.add(root, path, "feature/x-y", nil)
    assert :ok = Worktree.remove(root, path, false)
  end

  test "run without git on PATH", %{base: base} do
    assert {:error, "git not found"} = Worktree.run(["--version"], path: base)
  end
end
