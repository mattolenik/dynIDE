defmodule DynideServer.Detect.ManifestTest do
  use ExUnit.Case, async: true

  alias DynideServer.Detect.Manifest
  alias DynideServer.Detect.Manifest.{Gate, Rule}

  defp rule(body, id \\ "r"), do: ~s([[rules]]\nid = "#{id}"\nstate = "idle"\n) <> body <> "\n"
  defp doc(rules, head \\ ""), do: "id = \"x\"\n" <> head <> rules

  defp error(toml) do
    assert {:error, msg} = Manifest.parse(toml)
    msg
  end

  test "parses a one-rule manifest with defaults, lowercased contains and raw evidence" do
    toml =
      doc(
        rule("contains = ['Esc To Interrupt']\nany = [{ regex = ['^\\s*\\d+'] }]"),
        "version = \"2026.1.2\"\nmin_engine_version = 2\naliases = [\"x-code\"]\n"
      )

    assert {:ok, %Manifest{id: "x", version: "2026.1.2", min_engine_version: 2} = m} =
             Manifest.parse(toml)

    assert m.aliases == ["x-code"]
    assert [%Rule{id: "r", state: :idle, priority: 0, region: "whole_recent"} = r] = m.rules
    refute r.skip_state_update or r.visible_idle or r.visible_blocker or r.visible_working

    assert %Gate{contains: ["esc to interrupt"], any: [%Gate{regex: [{"^\\s*\\d+", mp}]}]} =
             r.gate

    assert {:match, _} = :re.run("  42", mp)

    assert r.evidence == %{
             contains: ["Esc To Interrupt"],
             regex: [],
             line_regex: [],
             all_count: 0,
             any_count: 1,
             not_count: 0
           }
  end

  test "trims the region and defaults a missing state to unknown" do
    toml = "id = \"x\"\n[[rules]]\nid = \"r\"\nregion = \" bottom_lines(3) \"\ncontains = ['a']\n"

    assert {:ok, %{rules: [%Rule{state: :unknown, region: "bottom_lines(3)"}]}} =
             Manifest.parse(toml)
  end

  test "rejects unknown keys, naming the key" do
    assert error(doc(rule("contains = ['a']"), "foo = 1\n")) =~ "foo"
    assert error(doc(rule("contains = ['a']\nfoo = 1"))) =~ "foo"
    assert error(doc(rule("any = [{ contains = ['a'], foo = 1 }]"))) =~ "foo"
  end

  test "rejects an empty rule list and more than 128 rules" do
    assert error("id = \"x\"\n") == "manifest must contain at least one rule"
    rules = Enum.map_join(1..129, &rule("contains = ['a']", "r#{&1}"))
    assert error(doc(rules)) == "manifest contains 129 rules, max is 128"
  end

  test "rejects skip_state_update without state unknown" do
    assert error(doc(rule("skip_state_update = true\ncontains = ['a']"))) ==
             "rule r uses skip_state_update without state = \"unknown\""
  end

  test "rejects invalid regions" do
    assert error(doc(rule("region = 'bottom_lines(x)'\ncontains = ['a']"))) ==
             "rule r uses invalid region: bottom_lines(x)"

    assert error(doc(rule("region = 'top_non_empty_lines(01)'\ncontains = ['a']"))) ==
             "rule r uses invalid region: top_non_empty_lines(01)"

    assert error(doc(rule("region = 'top_non_empty_lines(65536)'\ncontains = ['a']"))) =~
             "invalid region"

    assert error(
             doc(
               rule("region = 'top_non_empty_lines(5)'\ncontains = ['a']"),
               "min_engine_version = 2\n"
             )
           ) ==
             "rule r uses top_non_empty_lines but min_engine_version is below 3"
  end

  test "rejects gate depth 9 but accepts depth 8" do
    nest = fn n ->
      String.duplicate("{ all = [", n) <> "{ contains = ['a'] }" <> String.duplicate("] }", n)
    end

    assert {:ok, _} = Manifest.parse(doc(rule("all = [#{nest.(7)}]")))

    assert error(doc(rule("all = [#{nest.(8)}]"))) ==
             "rule r has invalid matcher gates: all gate exceeds max gate depth 8"
  end

  test "rejects an empty not gate" do
    assert error(doc(rule("contains = ['a']\nnot = [{}]"))) ==
             "rule r has invalid matcher gates: rule contains an empty not gate"
  end

  test "rejects a gate without a positive matcher" do
    assert error(doc(rule("not = [{ contains = ['a'] }]"))) ==
             "rule r has invalid matcher gates: rule must contain a positive matcher"
  end

  test "rejects an invalid regex, naming the rule and pattern" do
    assert error(doc(rule("regex = ['(']"))) =~
             ~s(rule r has invalid matcher gates: rule contains invalid regex pattern "(": )
  end

  test "rejects too many matchers and over-long matchers" do
    many = Enum.map_join(1..33, ", ", &"'m#{&1}'")
    assert error(doc(rule("contains = [#{many}]"))) =~ "rule has 33 direct matchers, max is 32"
    long = String.duplicate("a", 513)
    assert error(doc(rule("contains = ['#{long}']"))) =~ "rule matcher exceeds max length 512"
  end

  test "rejects wrong value types and bad versions" do
    assert error(doc(rule("contains = ['a']\npriority = 'high'"))) =~ "priority"

    assert error(~s(id = "x"\n[[rules]]\nid = "r"\nstate = "busy"\ncontains = ['a']\n)) =~
             "busy"

    assert error(doc(rule("contains = ['a']"), "version = \"1.x\"\n")) =~ "dotted numeric"
  end

  test "compile_regex keeps unicode escapes and translates Rust \\u escapes" do
    for src <- [~S"^[\x{2800}-\x{28FF}] ", ~S"^[\u2800-\u28FF] ", ~S"^[\u{2800}-\u{28ff}] "] do
      assert {:ok, mp} = Manifest.compile_regex(src)
      assert {:match, _} = :re.run("⠋ working", mp)
    end

    assert {:ok, mp} = Manifest.compile_regex(~S"\\u2800")
    assert {:match, _} = :re.run(~S"\u2800", mp)
    assert {:error, _} = Manifest.compile_regex("(")
  end

  test "compile_regex: $ matches only at the end of the text unless (?m), as in Rust" do
    assert {:ok, mp} = Manifest.compile_regex("a$")
    assert :nomatch = :re.run("a\n", mp)
    assert {:ok, mp} = Manifest.compile_regex("(?m)a$")
    assert {:match, _} = :re.run("a\nb", mp)
  end
end
