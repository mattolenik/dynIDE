defmodule DynideServer.App.Workspaces.LabelTest do
  use ExUnit.Case, async: true

  alias DynideServer.App.Workspaces.Label

  # outside the checkout: ExUnit's tmp_dir is inside this repo, whose .git would name it
  setup do
    tmp = Path.join(System.tmp_dir!(), "herdr-label-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  test "a repo dir and its subdirs name the repo", %{tmp_dir: tmp} do
    repo = Path.join(tmp, "herdr")
    File.mkdir_p!(Path.join([repo, ".git"]))
    File.mkdir_p!(Path.join([repo, "src", "app"]))
    assert Label.auto(repo) == "herdr"
    assert Label.auto(Path.join([repo, "src", "app"])) == "herdr"
    assert Label.auto(repo <> "/") == "herdr"
  end

  test "a linked worktree (.git file) names its own dir", %{tmp_dir: tmp} do
    wt = Path.join(tmp, "feature-x")
    File.mkdir_p!(Path.join(wt, "lib"))
    File.write!(Path.join(wt, ".git"), "gitdir: /elsewhere/.git/worktrees/feature-x\n")
    assert Label.auto(Path.join(wt, "lib")) == "feature-x"
  end

  test "a plain dir names itself; nil and / name nothing", %{tmp_dir: tmp} do
    plain = Path.join(tmp, "notes")
    File.mkdir_p!(plain)
    assert Label.auto(plain) == "notes"
    assert Label.auto(nil) == nil
    assert Label.auto("/") == nil
  end
end
