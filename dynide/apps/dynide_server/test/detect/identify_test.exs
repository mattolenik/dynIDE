defmodule DynideServer.Detect.IdentifyTest do
  use ExUnit.Case, async: true

  alias DynideServer.Detect.Identify

  defp job(processes, pgid \\ 10, shell \\ false),
    do: %{pgid: pgid, shell: shell, processes: processes}

  defp proc(pid, name, argv), do: %{pid: pid, name: name, argv: argv}

  test "label/1" do
    assert Identify.label("claude-code") == "claude"
    assert Identify.label("/opt/homebrew/bin/codex") == "codex"
    assert Identify.label("Cursor-Agent.exe") == "cursor"
    assert Identify.label("muse-bin-0.1.0-R708.1") == "muse"
    assert Identify.label("muse-binary") == nil
    assert Identify.label("muse-bin") == nil
    assert Identify.label("bash") == nil
    assert Enum.all?(Identify.labels(), &(Identify.label(&1) == &1))
  end

  test "node running a known package script" do
    p = proc(10, "node", ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"])
    assert Identify.agent(job([p])) == {"claude", 10}

    for {path, label} <- [
          {"/x/node_modules/@openai/codex/bin/codex.js", "codex"},
          {"/x/node_modules/opencode-ai/bin/opencode", "opencode"},
          {"/x/node_modules/@google/gemini-cli/dist/index.js", "gemini"}
        ] do
      assert Identify.agent(job([proc(10, "node", ["node", "--no-warnings", path])])) ==
               {label, 10}
    end
  end

  test "generic runtimes with eval, module or a plain script are not agents" do
    assert Identify.agent(job([proc(10, "node", ["node", "-e", "claude"])])) == nil
    assert Identify.agent(job([proc(10, "python3", ["python3", "-m", "claude"])])) == nil
    assert Identify.agent(job([proc(10, "python3", ["python3", "server.py"])])) == nil
    assert Identify.agent(job([proc(10, "bash", ["bash", "-c", "codex"])])) == nil
    assert Identify.agent(job([proc(10, "bun", ["bun", "/usr/bin/codex"])])) == {"codex", 10}
  end

  test "argv0 wins over the OS name" do
    assert Identify.agent(job([proc(10, "gsleep", ["claude"])])) == {"claude", 10}
    assert Identify.agent(job([proc(10, "claude", ["sleep", "1"])])) == nil
  end

  test "the group leader is preferred, else the highest priority" do
    leader = proc(10, "node", ["node", "/x/node_modules/@openai/codex/bin/codex.js"])
    child = proc(11, "claude", ["claude"])
    assert Identify.agent(job([child, leader])) == {"codex", 10}

    # no leader among the processes: the wrapped one (priority 3) beats a native binary (2)
    native = proc(12, "gemini", ["gemini"])
    wrapped = proc(13, "node", ["node", "/x/node_modules/@openai/codex/bin/codex.js"])
    assert Identify.agent(job([native, wrapped])) == {"codex", 13}
    assert Identify.agent(job([wrapped, native])) == {"codex", 13}
  end

  test "a plain shell job and an empty job are not agents" do
    assert Identify.agent(job([proc(10, "zsh", ["-zsh"])], 10, true)) == nil
    assert Identify.agent(job([proc(10, "bash", ["bash"])], 10, true)) == nil
    assert Identify.agent(job([])) == nil
  end

  # herdr identify_agent_process_in_job: no shell short-circuit, so `exec claude` (or a
  # pane spawned with an agent as its command) is identified as the pane's root process
  test "an agent that is the pane's root process is identified" do
    assert Identify.agent(job([proc(10, "claude", ["claude"])], 10, true)) == {"claude", 10}
  end

  # Captured on this host with the binary under a pty (python pty.fork + execv, no prompt
  # sent), `ps -o pid,ppid,pgid,tpgid,comm,args`: the process is its own group leader and
  # argv is the single execv path; comm is the same path (truncated by ps).
  test "processes observed for real agents" do
    # claude 2.1.310, codex-cli 0.164.0, opencode v2.0.22 (all native arm64 binaries)
    for {path, label} <- [
          {"/opt/homebrew/bin/claude", "claude"},
          {"/opt/homebrew/bin/codex", "codex"},
          {"/opt/homebrew/bin/opencode", "opencode"}
        ] do
      assert Identify.agent(job([proc(72_441, path, [path])], 72_441)) == {label, 72_441}

      assert Identify.agent(job([proc(72_441, Path.basename(path), [path])], 72_441)) ==
               {label, 72_441}
    end
  end

  test "helper files under a package dir are not agents" do
    for path <- [
          "/x/node_modules/@anthropic-ai/claude-code/vendor/ripgrep/arm64-darwin/rg",
          "/x/node_modules/@openai/codex/vendor/rg",
          "/x/node_modules/opencode-ai/lib/helper",
          "/x/node_modules/@google/gemini-cli/dist/other.js",
          "/x/node_modules/@earendil-works/pi-coding-agent/dist/other.js"
        ] do
      assert Identify.agent(job([proc(10, "node", ["node", path])])) == nil
    end
  end

  test "letta batch invocations are not agents" do
    assert Identify.agent(job([proc(10, "letta", ["letta"])])) == {"letta", 10}

    for flag <- ~w(-p --print -h --help -v --version --update --upgrade) do
      assert Identify.agent(job([proc(10, "letta", ["letta", flag])])) == nil
    end
  end

  test "script argument resolution" do
    cc = "/x/node_modules/@anthropic-ai/claude-code/cli.js"

    assert Identify.agent(job([proc(10, "npx", ["npx", "-y", "@anthropic-ai/claude-code"])])) ==
             {"claude", 10}

    assert Identify.agent(job([proc(10, "env", ["env", "FOO=1", "claude"])])) == nil
    assert Identify.agent(job([proc(10, "python3", ["python3", "-c", "codex"])])) == nil
    assert Identify.agent(job([proc(10, "python3", ["python3", "-m", "codex"])])) == nil
    assert Identify.agent(job([proc(10, "node", ["node", "--", cc])])) == {"claude", 10}
    assert Identify.agent(job([proc(10, "node", ["node", "-r", "x", cc])])) == {"claude", 10}
    assert Identify.agent(job([proc(10, "node", ["node", "-r", cc])])) == nil
  end
end
