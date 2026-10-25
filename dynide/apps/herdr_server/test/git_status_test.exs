defmodule HerdrServer.GitStatusTest do
  use ExUnit.Case, async: true

  alias HerdrServer.GitStatus

  test "parse: branch, ahead/behind, detached, no upstream" do
    normal = """
    # branch.oid 0123abc
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +0 -0
    1 .M N... 100644 100644 100644 abc def lib/x.ex
    """

    assert GitStatus.parse(normal) == %{branch: "main", ahead: 0, behind: 0}

    assert GitStatus.parse("# branch.head dynide/m17\n# branch.ab +3 -12\n") ==
             %{branch: "dynide/m17", ahead: 3, behind: 12}

    assert GitStatus.parse("# branch.oid abc\n# branch.head (detached)\n") ==
             %{branch: nil, ahead: 0, behind: 0}

    assert GitStatus.parse("# branch.oid (initial)\n# branch.head topic\n") ==
             %{branch: "topic", ahead: 0, behind: 0}

    assert GitStatus.parse("") == %{branch: nil, ahead: 0, behind: 0}
  end

  test "argv never takes optional locks" do
    assert ["--no-optional-locks", "-C", "/r", "status" | _] = GitStatus.argv("/r")
  end

  @tag :tmp_dir
  test "status: nil outside a repo, the branch inside one", %{tmp_dir: dir} do
    assert GitStatus.status(Path.join(dir, "missing")) == nil

    if System.find_executable("git") do
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "trunk", dir])
      assert %{branch: "trunk", ahead: 0, behind: 0} = GitStatus.status(dir)
    end
  end
end
