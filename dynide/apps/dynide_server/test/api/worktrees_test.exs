defmodule DynideServer.Api.WorktreesTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  @moduletag :git
  @moduletag skip: if(System.find_executable("git"), do: false, else: "git not installed")

  alias DynideServer.Api.{Listener, Spec}
  alias DynideServer.App.{Modal, Store, Worktrees}
  alias DynideServer.Persist.Facts
  alias DynideServer.Test.ApiClient

  @git ["-c", "user.email=t@t", "-c", "user.name=t"]

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | @git] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    tmp = Path.join(System.tmp_dir!(), "hwt#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "proj"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    git!(Path.join(tmp, "proj"), ["init", "-q", "-b", "main"])
    git!(Path.join(tmp, "proj"), ["commit", "-q", "--allow-empty", "-m", "init"])
    # git reports resolved paths (macOS tmp is a symlink)
    root = git!(Path.join(tmp, "proj"), ["rev-parse", "--show-toplevel"])
    base = Path.dirname(root)
    path = Path.join(System.tmp_dir!(), "hwa#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(path) end)
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    %{s: ApiClient.connect(path), root: root, base: base}
  end

  defp ok!(s, method, params) do
    reply = ApiClient.call(s, method, params)
    assert %{"result" => r} = reply, "#{method}: #{inspect(reply)}"
    assert Spec.validate_result(method, r) == :ok
    r
  end

  defp err(s, method, params) do
    assert %{"error" => %{"code" => code} = e} = ApiClient.call(s, method, params)
    {:ok, m} = Spec.fetch(method)
    assert String.to_existing_atom(code) in m.errors, "#{method}: #{code}"
    e
  end

  defp create!(s, root, base, branch, extra \\ %{}) do
    params = %{"cwd" => root, "branch" => branch, "path" => Path.join(base, "wt-" <> branch)}
    ok!(s, "worktree.create", Map.merge(params, extra))
  end

  test "create focuses a workspace in the checkout named by its label", %{s: s} = c do
    r = create!(s, c.root, c.base, "feat", %{"focus" => true})
    wt = Path.join(c.base, "wt-feat")

    assert %{"workspace_id" => "w2", "label" => "wt-feat", "focused" => true} = r["workspace"]

    assert %{"path" => ^wt, "branch" => "feat", "is_linked_worktree" => true} = r["worktree"]
    assert r["worktree"]["open_workspace_id"] == "w2"
    assert Facts.cwd(2) == wt

    assert %{auto_name: true, cwd: ^wt} =
             Enum.find(Store.snapshot().session.workspaces, &(&1.id == 2))

    # a second create of the same branch is git's error
    assert %{"code" => "failed", "message" => msg} =
             err(s, "worktree.create", %{
               "cwd" => c.root,
               "branch" => "feat",
               "path" => Path.join(c.base, "dup")
             })

    assert msg =~ "feat"
  end

  test "list shows each worktree and the workspace open in it", %{s: s} = c do
    create!(s, c.root, c.base, "feat")
    r = ok!(s, "worktree.list", %{"cwd" => c.root})

    assert r["source"] == %{
             "repo_name" => "proj",
             "repo_root" => c.root,
             "source_checkout_path" => c.root
           }

    assert [main, feat] = r["worktrees"]
    assert %{"path" => root, "branch" => "main", "is_linked_worktree" => false} = main
    assert root == c.root and main["open_workspace_id"] == nil and main["label"] == "proj"
    assert %{"branch" => "feat", "open_workspace_id" => "w2", "label" => "wt-feat"} = feat

    # from the worktree's own workspace
    r2 = ok!(s, "worktree.list", %{"workspace_id" => "w2"})
    assert r2["worktrees"] == r["worktrees"]
  end

  test "open on an existing branch, then again focuses the same workspace", %{s: s} = c do
    other = Path.join(c.base, "other")
    git!(c.root, ["worktree", "add", "-q", "-b", "other", other])

    r = ok!(s, "worktree.open", %{"cwd" => c.root, "branch" => "other", "label" => "mine"})

    assert %{"already_open" => false, "workspace" => %{"workspace_id" => "w2", "label" => "mine"}} =
             r

    assert r["workspace"]["focused"] == false

    again = ok!(s, "worktree.open", %{"cwd" => c.root, "path" => other, "focus" => true})

    assert %{"already_open" => true, "workspace" => %{"workspace_id" => "w2", "focused" => true}} =
             again

    # a label on an already-open checkout renames it (a custom name)
    renamed = ok!(s, "worktree.open", %{"cwd" => c.root, "branch" => "other", "label" => "ren"})
    assert %{"already_open" => true, "workspace" => %{"label" => "ren"}} = renamed
    assert %{auto_name: false} = Enum.find(Store.snapshot().session.workspaces, &(&1.id == 2))

    assert %{"code" => "not_found"} =
             err(s, "worktree.open", %{"cwd" => c.root, "branch" => "nope"})

    assert %{"code" => "invalid_params"} = err(s, "worktree.open", %{"cwd" => c.root})
  end

  test "remove refuses a dirty worktree, force removes it and closes its workspace",
       %{s: s} = c do
    create!(s, c.root, c.base, "feat")
    wt = Path.join(c.base, "wt-feat")
    File.write!(Path.join(wt, "x.txt"), "x")

    assert %{"code" => "failed", "message" => msg, "data" => %{"reason" => "dirty"}} =
             err(s, "worktree.remove", %{"workspace_id" => "w2"})

    assert msg =~ "dirty"
    assert File.dir?(wt)

    assert %{"workspace_id" => "w2", "path" => ^wt, "forced" => true} =
             ok!(s, "worktree.remove", %{"workspace_id" => "w2", "force" => true})

    refute File.exists?(wt)
    assert Enum.map(Store.snapshot().session.workspaces, & &1.id) == [1]
    # the branch is kept
    assert git!(c.root, ["branch", "--list", "feat"]) =~ "feat"

    # the main checkout is not a linked worktree
    ok!(s, "worktree.open", %{"cwd" => c.root, "branch" => "main"})
    assert %{"code" => "failed"} = err(s, "worktree.remove", %{"workspace_id" => "w3"})
  end

  test "create and open refuse a linked-worktree source; list allows it", %{s: s} = c do
    create!(s, c.root, c.base, "feat")
    wt = Path.join(c.base, "wt-feat")
    msg = "New and open worktree actions start from the repo parent workspace."

    for {method, params} <- [
          {"worktree.create",
           %{"cwd" => wt, "branch" => "b2", "path" => Path.join(c.base, "b2")}},
          {"worktree.open", %{"workspace_id" => "w2", "branch" => "main"}}
        ] do
      assert %{
               "code" => "failed",
               "message" => ^msg,
               "data" => %{"reason" => "linked_worktree_source"}
             } =
               err(s, method, params)
    end

    refute File.exists?(Path.join(c.base, "b2"))
    assert length(ok!(s, "worktree.list", %{"cwd" => wt})["worktrees"]) == 2
  end

  test "a non-repo cwd and a missing git answer failed with git's message", %{s: s} = c do
    plain = Path.join(c.base, "plain")
    File.mkdir_p!(plain)

    assert %{"code" => "failed", "message" => msg} = err(s, "worktree.list", %{"cwd" => plain})
    assert msg =~ "not a git repository"

    assert %{"code" => "invalid_params"} = err(s, "worktree.list", %{"cwd" => "rel"})

    old = System.get_env("PATH")
    System.put_env("PATH", plain)

    try do
      assert %{"code" => "failed", "message" => "git not found"} =
               err(s, "worktree.create", %{"cwd" => c.root, "branch" => "b"})
    after
      System.put_env("PATH", old)
    end
  end

  test "the keybind flow runs git in a task and opens the list menu", c do
    {:ok, _, _} = Store.request({Worktrees, :open, [c.root, "proj", true]})
    {:ok, _, _} = Store.request({Worktrees, :list, [2]})

    menu = wait(fn -> Modal.top(Store.snapshot()) end)
    assert %{kind: :menu, items: [{0, "proj (main)", {_, :switch_workspace_id, [2]}}]} = menu
  end

  defp wait(fun, n \\ 100) do
    case fun.() do
      nil when n > 0 ->
        Process.sleep(20)
        wait(fun, n - 1)

      v ->
        v
    end
  end
end
