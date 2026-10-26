defmodule DynideServer.Detect.EngineTest do
  use ExUnit.Case, async: true

  alias DynideServer.Detect.{Engine, Manifest}
  alias DynideServer.Detect.Engine.Detection

  defp entry(toml, extra \\ %{}) do
    {:ok, m} = Manifest.parse(~s(id = "x"\nversion = "1.2"\n) <> toml)

    Map.merge(
      %{
        agent: "x",
        manifest: m,
        source: :bundled,
        path: nil,
        version: m.version,
        warning: nil,
        error: nil
      },
      extra
    )
  end

  defp input(screen, title \\ ""), do: %{screen: screen, osc_title: title, osc_progress: ""}

  defp detect(toml, screen), do: Engine.detect(entry(toml), input(screen))

  test "highest priority wins over file order" do
    toml = """
    [[rules]]
    id = "low"
    state = "idle"
    contains = ["a"]
    [[rules]]
    id = "high"
    state = "working"
    priority = 5
    contains = ["a"]
    """

    assert %Detection{state: :working, rule: "high"} = detect(toml, "a")
  end

  test "a priority tie keeps the first rule in file order" do
    toml = """
    [[rules]]
    id = "first"
    state = "idle"
    contains = ["A"]
    [[rules]]
    id = "second"
    state = "working"
    contains = ["a"]
    """

    assert %Detection{state: :idle, rule: "first"} = detect(toml, "xAx")
  end

  test "a not gate vetoes" do
    toml = """
    [[rules]]
    id = "r"
    state = "working"
    contains = ["busy"]
    not = [{ contains = ["done"] }]
    """

    assert %Detection{rule: "r"} = detect(toml, "busy")
    assert %Detection{rule: nil, state: :idle} = detect(toml, "busy done")
  end

  test "any needs one match" do
    toml = """
    [[rules]]
    id = "r"
    state = "working"
    any = [{ contains = ["foo"] }, { contains = ["bar"] }]
    """

    assert %Detection{rule: "r"} = detect(toml, "bar")
    assert %Detection{rule: nil} = detect(toml, "baz")
  end

  test "nested all/any to depth 3" do
    toml = """
    [[rules]]
    id = "r"
    state = "blocked"
    all = [{ any = [{ all = [{ contains = ["x"] }, { contains = ["y"] }] }, { contains = ["z"] }] }]
    """

    assert %Detection{rule: "r"} = detect(toml, "x y")
    assert %Detection{rule: "r"} = detect(toml, "z")
    assert %Detection{rule: nil} = detect(toml, "x")
  end

  test "line_regex matches per line, regex over the region with (?m)" do
    line = "[[rules]]\nid = \"r\"\nstate = \"idle\"\nline_regex = ['^b$']\n"
    whole = "[[rules]]\nid = \"r\"\nstate = \"idle\"\nregex = ['^b$']\n"
    multi = "[[rules]]\nid = \"r\"\nstate = \"idle\"\nregex = ['(?m)^b$']\n"

    assert %Detection{rule: "r"} = detect(line, "a\nb\nc")
    assert %Detection{rule: nil} = detect(whole, "a\nb\nc")
    assert %Detection{rule: "r"} = detect(multi, "a\nb\nc")
  end

  test "osc_title region reads the osc title" do
    toml =
      "[[rules]]\nid = \"r\"\nstate = \"working\"\nregion = \"osc_title\"\ncontains = [\"spin\"]\n"

    assert %Detection{rule: "r"} = Engine.detect(entry(toml), input("plain", "spin"))
    assert %Detection{rule: nil} = Engine.detect(entry(toml), input("spin", ""))
  end

  test "visible flags only on the rule's own state" do
    toml = """
    [[rules]]
    id = "b"
    state = "blocked"
    visible_blocker = true
    visible_working = true
    contains = ["allow?"]
    """

    assert %Detection{visible_blocker: true, visible_working: false, visible_idle: false} =
             detect(toml, "allow?")
  end

  test "a skip rule returns skip_state_update with state unknown" do
    toml =
      "[[rules]]\nid = \"s\"\nstate = \"unknown\"\nskip_state_update = true\ncontains = [\"q\"]\n"

    assert %Detection{state: :unknown, skip_state_update: true, rule: "s"} = detect(toml, "q")
  end

  test "no match falls back to idle with a reason" do
    e = entry(~s([[rules]]\nid = "r"\nstate = "working"\ncontains = ["busy"]\n))
    assert %Detection{state: :idle, rule: nil} = Engine.detect(e, input("calm"))

    assert %{"fallback_reason" => "default_known_agent_idle_fallback"} =
             Engine.explain("x", e, input("calm"))
  end

  test "an entry with an error falls back to idle with the error as warning" do
    e = %{
      agent: "x",
      manifest: nil,
      source: :bundled,
      path: nil,
      version: nil,
      warning: nil,
      error: "bad"
    }

    assert %Detection{state: :idle} = Engine.detect(e, input("x"))

    assert %{"state" => "idle", "warning" => "bad", "evaluated_rules" => []} =
             Engine.explain("x", e, input("x"))
  end

  test "an unknown agent is unknown" do
    assert %Detection{state: :unknown, rule: nil} = Engine.detect(nil, input("x"))

    assert %{"agent" => "nope", "state" => "unknown", "fallback_reason" => "unknown_agent"} =
             Engine.explain("nope", nil, input("x"))
  end

  test "a catastrophic pattern hits the match limit, counts as no match, and is fast" do
    toml = "[[rules]]\nid = \"r\"\nstate = \"working\"\nregex = ['^(a+)+$']\n"
    e = entry(toml)
    screen = input(String.duplicate("a", 2000) <> "b")

    {us, d} = :timer.tc(fn -> Engine.detect(e, screen) end)
    assert %Detection{rule: nil, state: :idle} = d
    assert d.limit_hits >= 1
    assert us < 50_000
    assert Engine.explain("x", e, screen)["limit_hits"] >= 1
  end

  @two """
  [[rules]]
  id = "busy"
  state = "working"
  priority = 2
  region = "bottom_lines(1)"
  contains = ["Esc to interrupt"]
  [[rules]]
  id = "prompt"
  state = "idle"
  regex = ['^> ']
  """

  test "explain lists every rule with matched and evidence" do
    long = String.duplicate("é", 300)
    ex = Engine.explain("x", entry(@two), input(long <> "\nesc to interrupt"))

    assert %{
             "agent" => "x",
             "state" => "working",
             "manifest_source" => "bundled",
             "manifest_version" => "1.2",
             "matched_rule" => %{
               "id" => "busy",
               "priority" => 2,
               "region" => "bottom_lines(1)",
               "state" => "working"
             },
             "visible_idle" => false,
             "screen_detection_skipped" => false,
             "skip_state_update" => false,
             "skipped_update_reason" => nil,
             "fallback_reason" => nil,
             "warning" => nil,
             "limit_hits" => 0,
             "evaluated_rules" => [busy, prompt]
           } = ex

    assert %{
             "id" => "busy",
             "matched" => true,
             "region" => "bottom_lines(1)",
             "state" => "working"
           } = busy

    assert busy["evidence"] == %{
             "contains" => ["Esc to interrupt"],
             "regex" => [],
             "line_regex" => [],
             "all_count" => 0,
             "any_count" => 0,
             "not_count" => 0,
             "region_bytes" => 16,
             "region_preview" => "esc to interrupt"
           }

    assert %{"id" => "prompt", "matched" => false, "priority" => 0} = prompt
    assert prompt["evidence"]["region_bytes"] == 617
    assert prompt["evidence"]["region_preview"] == String.duplicate("é", 240) <> "..."
  end

  test "explain_text exact lines for a matched case" do
    ex = Engine.explain("x", entry(@two), input("> hi"))

    assert Engine.explain_text(ex, false) ==
             """
             agent: x
             state: idle
             manifest: bundled 1.2
             rule: prompt (region=whole_recent priority=0)
             evidence: "> hi"
             """

    assert Engine.explain_text(ex, true) ==
             """
             agent: x
             state: idle
             manifest: bundled 1.2
             rule: prompt (region=whole_recent priority=0)
             evidence: "> hi"
             visible: idle=false blocker=false working=false
             evaluated_rules:
               ✗ busy priority=2 region=bottom_lines(1) state=working
                 matchers: contains=["Esc to interrupt"] regex=[] line_regex=[] all=0 any=0 not=0
                 region: bytes=4 preview="> hi"
               ✓ prompt priority=0 region=whole_recent state=idle
                 matchers: contains=[] regex=["^> "] line_regex=[] all=0 any=0 not=0
                 region: bytes=4 preview="> hi"
             """
  end

  test "explain_text without a match" do
    ex = Engine.explain("nope", nil, input(""))

    assert Engine.explain_text(ex, false) ==
             "agent: nope\nstate: unknown\nmanifest: none unknown\nrule: none\nfallback_reason: unknown_agent\n"
  end

  test "explain_text prints the screen detection skip reason after the fallback reason" do
    ex = %{
      "agent" => "claude",
      "state" => "working",
      "matched_rule" => nil,
      "fallback_reason" => "x",
      "screen_detection_skip_reason" => "full_lifecycle_hook_authority"
    }

    assert Engine.explain_text(ex, false) ==
             "agent: claude\nstate: working\nmanifest: none unknown\nrule: none\n" <>
               "fallback_reason: x\nscreen_detection_skip_reason: full_lifecycle_hook_authority\n"
  end
end
