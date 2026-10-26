defmodule DynideServer.AgentResumeTest do
  use ExUnit.Case, async: true

  alias DynideServer.AgentResume

  defp plan(agent, kind, value), do: AgentResume.plan(%{agent: agent, kind: kind, value: value})

  test "plan: herdr's argv per agent" do
    assert plan("claude", :id, "i") == {:ok, ~w(claude --resume i)}
    assert plan("codex", :id, "i") == {:ok, ~w(codex resume i)}
    assert plan("droid", :id, "i") == {:ok, ~w(droid --resume i)}
    assert plan("opencode", :id, "i") == {:ok, ~w(opencode --session i)}
    assert plan("pi", :path, "/s.jsonl") == {:ok, ~w(pi --session /s.jsonl)}
    assert plan("pi", :id, "i") == {:ok, ~w(pi --session i)}
    assert plan("omp", :path, "/s") == {:ok, ~w(omp --resume=/s)}
    assert plan("copilot", :id, "i") == {:ok, ~w(copilot --resume=i)}
    assert plan("cursor", :id, "i") == {:ok, ~w(cursor-agent --resume i)}
    assert plan("letta", :id, "default:a") == {:ok, ~w(letta --conversation default --agent a)}
    assert plan("letta", :id, "default:") == :none
    assert plan("x", :argv, ~w(x --go)) == {:ok, ~w(x --go)}
    # a path only for pi and omp; unknown agents; an argv that fails validation
    assert plan("claude", :path, "/s") == :none
    assert plan("nope", :id, "i") == :none
    assert plan("claude", :id, "it's") == :none
    assert plan("x", :argv, ["/bin/x"]) == :none
    assert AgentResume.plan(nil) == :none
  end

  test "validate: limits" do
    assert AgentResume.validate(["prime-agent", "--model", "gpt 6"]) == :ok
    assert AgentResume.validate(["c_1.v-x", "--a=b"]) == :ok
    assert AgentResume.validate(List.duplicate("a", 64)) == :ok
    assert AgentResume.validate(["a", String.duplicate("x", 8191)]) == :ok

    for bad <- [
          [],
          [""],
          ["/usr/bin/x"],
          ["-x"],
          ["c++"],
          ["x", "a\\b"],
          ["prime agent"],
          ["x", "bad\nline"],
          ["x", "c1\u0085"],
          ["x", "can's"],
          ["x", <<0xFF>>],
          List.duplicate("a", 65),
          ["a", String.duplicate("x", 8192)]
        ] do
      assert {:error, _} = AgentResume.validate(bad), inspect(bad)
    end
  end

  test "shell: POSIX single quotes keep spaces in one word" do
    assert AgentResume.shell(["x", "a b", "--k=v"]) == "'x' 'a b' '--k=v'"

    {out, 0} =
      System.cmd("sh", ["-c", "printf '%s|' " <> AgentResume.shell(["a b", "$HOME", "c"])])

    assert out == "a b|$HOME|c|"
  end

  describe "from_report/1" do
    defp report(p),
      do: AgentResume.from_report(Map.merge(%{source: "herdr:claude", agent: "claude"}, p))

    test "an id from the official source; anything else is nothing resumable" do
      assert report(%{agent_session_id: "i"}) == {:ok, %{agent: "claude", kind: :id, value: "i"}}
      assert report(%{source: "hook", agent_session_id: "i"}) == {:ok, nil}
      assert report(%{}) == {:ok, nil}
      assert report(%{agent_session_id: String.duplicate("i", 513)}) == {:ok, nil}
      assert report(%{agent: " ", agent_session_id: "i"}) == {:error, "agent must not be empty"}
    end

    test "pi and omp prefer an absolute path" do
      p = %{source: "herdr:pi", agent: "pi", agent_session_id: "i", agent_session_path: "/s"}
      assert report(p) == {:ok, %{agent: "pi", kind: :path, value: "/s"}}

      assert report(%{p | agent_session_path: "rel"}) ==
               {:ok, %{agent: "pi", kind: :id, value: "i"}}

      assert {:ok, %{kind: :id}} =
               report(%{source: "herdr:antigravity_cli", agent: "agy", agent_session_id: "i"})

      assert {:ok, nil} = report(%{source: "herdr:agy", agent: "agy", agent_session_id: "i"})
    end

    test "a resume_argv is refused until M11's pane claim" do
      assert {:error, "resume_argv requires the reporter to hold the pane; " <> _} =
               report(%{agent_session_id: "i", resume_argv: ~w(x --go)})
    end
  end
end
