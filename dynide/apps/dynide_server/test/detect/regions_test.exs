defmodule DynideServer.Detect.RegionsTest do
  use ExUnit.Case, async: true

  alias DynideServer.Detect.Regions

  defp r(screen, spec),
    do: Regions.region(%{screen: screen, osc_title: "T", osc_progress: "P"}, spec)

  @codex "history\n• ran tests\nok\n› fix it\nfooter\n"
  @stale "› old\n• output\n"
  @box "above\nlast above\n\n────────\n> type here\nmore\n────────\nstatus\n"

  test "lines follows Rust str::lines" do
    assert Regions.lines("") == []
    assert Regions.lines("a\r\nb\n") == ["a", "b"]
    assert Regions.lines("a\n\nb") == ["a", "", "b"]
    assert Regions.lines("\n") == [""]
  end

  test "whole_recent is the whole screen, trimmed spec" do
    assert r(@codex, " whole_recent ") == @codex
  end

  test "osc regions read the osc fields" do
    assert r(@codex, "osc_title") == "T"
    assert r(@codex, "osc_progress") == "P"
  end

  test "after_last_prompt_marker" do
    assert r(@codex, "after_last_prompt_marker") == "footer\n"
    assert r("no prompt\n", "after_last_prompt_marker") == "no prompt\n"
    assert r("x\n›\ny", "after_last_prompt_marker") == "y"
  end

  test "before_current_prompt_marker" do
    assert r(@codex, "before_current_prompt_marker") == "history\n• ran tests\nok\n"
    assert r(@stale, "before_current_prompt_marker") == @stale
  end

  test "whole_recent_without_current_prompt_marker" do
    assert r(@codex, "whole_recent_without_current_prompt_marker") == ""
    assert r(@stale, "whole_recent_without_current_prompt_marker") == @stale
  end

  test "current_prompt_block_marker" do
    assert r(@codex, "current_prompt_block_marker") == "• ran tests"
    assert r(@stale, "current_prompt_block_marker") == ""
    assert r("› x\n", "current_prompt_block_marker") == ""
  end

  test "after_current_prompt_block_marker" do
    assert r(@codex, "after_current_prompt_block_marker") ==
             "• ran tests\nok\n› fix it\nfooter\n"

    assert r(@stale, "after_current_prompt_block_marker") == ""
  end

  test "block markers" do
    for m <- ["■", "✗", "✓"],
        do: assert(r("#{m} done\n› \n", "current_prompt_block_marker") == "#{m} done")
  end

  test "prompt_box_body is between the last two rules" do
    assert r(@box, "prompt_box_body") == "> type here\nmore\n"
    assert r("────\nonly one\n", "prompt_box_body") == ""
  end

  test "above_prompt_box" do
    assert r(@box, "above_prompt_box") == "above\nlast above\n\n"
    assert r("plain\n", "above_prompt_box") == "plain\n"
  end

  test "last_non_empty_above_prompt_box" do
    assert r(@box, "last_non_empty_above_prompt_box") == "last above"
  end

  test "after_last_horizontal_rule" do
    assert r(@box, "after_last_horizontal_rule") == "status\n"
    assert r("no rule\nhere", "after_last_horizontal_rule") == "no rule\nhere"
    assert r("x\n────", "after_last_horizontal_rule") == ""
  end

  test "horizontal rules: all dashes, or three or more dashes then anything" do
    assert r("a\n  ─ \nb", "after_last_horizontal_rule") == "b"
    assert r("a\n─── title\nb", "after_last_horizontal_rule") == "b"
    assert r("a\n── title\nb", "after_last_horizontal_rule") == "a\n── title\nb"
  end

  test "bottom_lines(N)" do
    assert r("a\nb\nc\n", "bottom_lines(2)") == "b\nc\n"
    assert r("a\nb\n", "bottom_lines(5)") == "a\nb\n"
  end

  test "bottom_non_empty_lines(N) skips blank lines" do
    assert r("a\nb\n\nc\n  \n", "bottom_non_empty_lines(2)") == "b\n\nc\n  \n"
    assert r("\n \n", "bottom_non_empty_lines(2)") == ""
  end

  test "top_non_empty_lines(N)" do
    assert r("\na\n\nb\nc\n", "top_non_empty_lines(2)") == "\na\n\nb\n"
    assert r("a\n", "top_non_empty_lines(0)") == ""
    assert r("a\n", "top_non_empty_lines(65536)") == ""
  end

  test "unknown region is empty" do
    assert r("a\n", "nope") == ""
  end
end
