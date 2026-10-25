defmodule HerdrServer.Plugins.InstallTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Plugins.{Command, Install, Paths, Registry}
  alias HerdrServer.Test.PluginDirs

  setup do
    %{base: PluginDirs.use_tmp()}
  end

  describe "Command.run/4" do
    test "exit status, stdout and stderr apart", %{base: base} do
      assert %{exit_code: 3, stdout: "out\n", stderr: "err\n", error: nil} =
               Command.run(["sh", "-c", "echo out; echo err >&2; exit 3"], base, [], [])
    end

    test "env is passed and cwd is the given dir", %{base: base} do
      assert %{exit_code: 0, stdout: out} =
               Command.run(["sh", "-c", "echo $FOO; pwd"], base, [{"FOO", "bar"}], [])

      assert ["bar", cwd] = String.split(out, "\n", trim: true)
      assert Path.basename(cwd) == Path.basename(base)
    end

    test "output is capped per stream", %{base: base} do
      %{exit_code: 0, stdout: out} =
        Command.run(["sh", "-c", "yes | head -c 200000"], base, [], [])

      marker = "\n[herdr truncated plugin output after 65536 bytes]"
      assert byte_size(out) == 65_536 + byte_size(marker)
      assert String.ends_with?(out, marker)

      %{stdout: out, stderr: err} =
        Command.run(
          ["sh", "-c", "yes 2>/dev/null | head -c 200; printf 0123456789abc >&2"],
          base,
          [],
          cap: 10
        )

      assert out == "y\ny\ny\ny\ny\n" <> "\n[herdr truncated plugin output after 10 bytes]"
      assert err == "0123456789" <> "\n[herdr truncated plugin output after 10 bytes]"
      assert %{stdout: "0123456789"} = Command.run(["printf", "0123456789"], base, [], cap: 10)
    end

    test "the run ends when the command exits, not when a descendant closes stdout",
         %{base: base} do
      pidfile = base <> "/bg.pid"
      t0 = System.monotonic_time(:millisecond)

      assert %{exit_code: 0, stdout: "hi\n"} =
               Command.run(["sh", "-c", "sleep 5 & echo $! >#{pidfile}; echo hi"], base, [], [])

      elapsed = System.monotonic_time(:millisecond) - t0
      System.cmd("kill", [String.trim(File.read!(pidfile))], stderr_to_stdout: true)
      assert elapsed < 1000
    end

    test "a timeout kills the OS process", %{base: base} do
      t0 = System.monotonic_time(:millisecond)

      assert %{exit_code: nil, error: "timed out"} =
               Command.run(["sleep", "30"], base, [], timeout_ms: 300)

      assert System.monotonic_time(:millisecond) - t0 < 1300
    end

    test "a timeout kills the whole process group and closes the port", %{base: base} do
      mine = fn ->
        Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, self()}))
      end

      before = mine.()
      t0 = System.monotonic_time(:millisecond)

      assert %{error: "timed out"} =
               Command.run(["sh", "-c", "sleep 61 & sleep 62"], base, [], timeout_ms: 500)

      assert System.monotonic_time(:millisecond) - t0 < 3000
      assert mine.() == before
      refute_received {_, {:data, _}}
      {ps, 0} = System.cmd("ps", ["-ax", "-o", "command"])
      refute ps =~ ~r/^sleep 6[12]$/m
    end

    test "the stderr file lives in a private dir under tmp_dir, removed after", %{base: base} do
      tmp = base <> "/t"
      assert %{stderr: "e\n"} = Command.run(["sh", "-c", "echo e >&2"], base, [], tmp_dir: tmp)
      assert File.stat!(tmp).mode |> Bitwise.band(0o777) == 0o700
      assert File.ls!(tmp) == []
    end

    test "a missing executable is an error, ./x resolves against cwd", %{base: base} do
      assert %{exit_code: nil, error: "command not found: nope-xyz"} =
               Command.run(["nope-xyz"], base, [], [])

      File.write!(base <> "/x.sh", "#!/bin/sh\necho hi\n")
      File.chmod!(base <> "/x.sh", 0o755)
      assert %{exit_code: 0, stdout: "hi\n"} = Command.run(["./x.sh"], base, [], [])
    end
  end

  defp git!(args, cwd) do
    {out, 0} =
      System.cmd("git", args,
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}]
      )

    out
  end

  # a bare repo at <base>/git/owner/repo.git holding `src`'s files
  defp bare_repo(base, src) do
    work = base <> "/work"
    File.mkdir_p!(work)
    for f <- File.ls!(src), do: File.cp_r!(Path.join(src, f), Path.join(work, f))
    git!(["init", "-q", "-b", "main"], work)
    git!(["add", "."], work)
    git!(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], work)
    File.mkdir_p!(base <> "/git/owner")
    git!(["clone", "-q", "--bare", work, base <> "/git/owner/repo.git"], base)
    File.rm_rf!(work)
  end

  test "link registers without building; uninstall unregisters and keeps files", %{base: base} do
    dir = PluginDirs.plugin(base <> "/p", "t.p", ~s([[build]]\ncommand = ["false"]))

    assert {:ok, %{"plugin_id" => "t.p", "enabled" => true, "source" => %{"kind" => "local"}}} =
             Install.link(dir, true)

    assert File.dir?(Paths.plugin_config_dir("t.p"))
    assert File.dir?(Paths.plugin_state_dir("t.p"))
    assert {:ok, %{"enabled" => false}} = Install.set_enabled("t.p", false)
    assert {:ok, "t.p"} = Install.uninstall("t.p")
    assert Registry.entries() == []
    assert File.exists?(Path.join(dir, "herdr-plugin.toml"))
    assert {:error, "plugin_not_found", _} = Install.uninstall("t.p")
    assert {:error, "plugin_not_found", _} = Install.set_enabled("t.p", true)
  end

  test "link reports the manifest reason", %{base: base} do
    assert {:error, "plugin_manifest_not_found", _} = Install.link(base <> "/none", true)
  end

  test "install from a local copy without yes previews the build and registers nothing" do
    src = Path.join(PluginDirs.examples(), "rust-release-check")

    assert {:error, "confirmation_required", msg, preview} = Install.install(src, nil, false)
    assert msg =~ "--yes"
    assert preview.build == [["cargo", "build", "--release"]]
    assert preview.plugin_id == "examples.rust-release-check"
    assert [%{"id" => "check"}] = preview.actions
    assert Registry.entries() == []
    refute File.exists?(Paths.installations_dir("examples.rust-release-check") <> "/1")
  end

  test "install from GitHub shorthand clones, registers with a github source", %{base: base} do
    bare_repo(base, Path.join(PluginDirs.examples(), "dev-layout-bootstrap"))

    Application.put_env(
      :herdr_server,
      :plugins,
      Application.get_env(:herdr_server, :plugins) ++ [git_base: "file://#{base}/git/"]
    )

    assert {:ok, p} = Install.install("owner/repo", nil, true)
    assert p["plugin_id"] == "examples.dev-layout-bootstrap"

    assert %{
             "kind" => "github",
             "owner" => "owner",
             "repo" => "repo",
             "resolved_commit" => <<_::binary-40>>
           } =
             p["source"]

    assert p["plugin_root"] == Paths.installations_dir(p["plugin_id"]) <> "/1"
    assert {:ok, %{"plugin_id" => "examples.dev-layout-bootstrap"}} = Registry.find("owner/repo")

    # a second install goes to a fresh dir and keeps the old one
    assert {:ok, p2} = Install.install("owner/repo", "main", true)
    assert p2["plugin_root"] == Paths.installations_dir(p["plugin_id"]) <> "/2"
    assert File.dir?(p["plugin_root"])
    assert p2["source"]["requested_ref"] == "main"
    assert {:ok, _} = Install.uninstall("owner/repo")
  end

  test "a failing build aborts and registers nothing", %{base: base} do
    src =
      PluginDirs.plugin(
        base <> "/src",
        "t.b",
        ~s([[build]]\ncommand = ["sh", "-c", "echo boom >&2; exit 4"])
      )

    assert {:error, "plugin_build_failed", msg} = Install.install(src, nil, true)
    assert msg =~ "build: 1/1"
    assert msg =~ "status: 4"
    assert msg =~ "boom"
    assert msg =~ "sh -c"
    assert Registry.entries() == []

    assert {:error, "plugin_build_failed", _} =
             Install.install(
               PluginDirs.plugin(base <> "/f", "t.f", ~s([[build]]\ncommand = ["false"])),
               nil,
               true
             )
  end

  test "a passing build runs in the plugin root without plugin env", %{base: base} do
    System.put_env("HERDR_PLUGIN_ID", "leak")
    on_exit(fn -> System.delete_env("HERDR_PLUGIN_ID") end)
    build = ~s([[build]]\ncommand = ["sh", "-c", "echo ${HERDR_PLUGIN_ID:-none} > built"])
    src = PluginDirs.plugin(base <> "/src", "t.ok", build)
    File.mkdir_p!(src <> "/.git")

    assert {:ok, p} = Install.install(src, nil, true)

    assert File.read!(p["plugin_root"] <> "/built") == "none\n"
    refute File.exists?(p["plugin_root"] <> "/.git")
    assert p["source"]["kind"] == "local"
  end

  test "installing over a linked plugin is refused", %{base: base} do
    dir = PluginDirs.plugin(base <> "/p", "t.p")
    {:ok, _} = Install.link(dir, true)
    assert {:error, "plugin_install_over_link", _} = Install.install(dir, nil, true)
  end

  test "a GitHub subdir that is a symlink out of the checkout is refused", %{base: base} do
    src = PluginDirs.plugin(base <> "/src", "t.s")
    File.mkdir_p!(base <> "/outside")
    PluginDirs.plugin(base <> "/outside", "t.out")
    File.ln_s!(base <> "/outside", src <> "/sub")
    bare_repo(base, src)

    Application.put_env(
      :herdr_server,
      :plugins,
      Application.get_env(:herdr_server, :plugins) ++ [git_base: "file://#{base}/git/"]
    )

    assert {:error, "invalid_plugin_source", _} = Install.install("owner/repo/sub", nil, false)
    assert {:ok, %{"plugin_id" => "t.s"}} = Install.install("owner/repo", nil, true)
  end

  test "relative local paths and option-like refs are refused" do
    assert {:error, "invalid_plugin_path", _} = Install.link("rel/dir", true)
    assert {:error, "invalid_plugin_source", _} = Install.install("./x", nil, false)

    assert {:error, "invalid_plugin_source", _} =
             Install.install("owner/repo", "--upload-pack=x", false)
  end

  test "bad GitHub shorthand is refused" do
    for s <- ["owner", "https://github.com/a/b", "a/../b", "a b/c"] do
      assert {:error, "invalid_plugin_source", _} = Install.install(s, nil, false), s
    end
  end
end
