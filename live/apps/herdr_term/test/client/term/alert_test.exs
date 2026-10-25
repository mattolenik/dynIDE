defmodule HerdrTerm.Client.Term.AlertTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Client.Term.Alert

  defp alert(sound \\ :done),
    do: %{
      kind: :notification,
      level: :done,
      title: "pi finished",
      body: "w · 1",
      pane: 1,
      sound: sound
    }

  defp props(delivery, enabled \\ true),
    do: %{toast: %{delivery: delivery}, sound: %{enabled: enabled}}

  test "herdr delivery draws from the scene: only the sound" do
    assert Alert.actions(alert(), props(:herdr)) == [{:sound, "done"}]
    assert Alert.actions(alert(:request), props(:herdr)) == [{:sound, "request"}]
    assert Alert.actions(alert(nil), props(:herdr)) == []
  end

  test "terminal delivery writes OSC 9 with title and body" do
    assert Alert.actions(alert(), props(:terminal)) == [
             {:osc9, "pi finished: w · 1"},
             {:sound, "done"}
           ]
  end

  test "off and system (a recorded gap) deliver nothing but the sound" do
    for d <- [:off, :system], do: assert(Alert.actions(alert(), props(d)) == [{:sound, "done"}])
  end

  test "a disabled sound is silent" do
    assert Alert.actions(alert(), props(:terminal, false)) == [{:osc9, "pi finished: w · 1"}]
  end

  test "a sound-only alert (no title) gets no OSC 9" do
    a = %{alert(:request) | title: nil, body: nil}
    assert Alert.actions(a, props(:terminal)) == [{:sound, "request"}]
  end

  test "missing props: herdr delivery, sound on" do
    assert Alert.actions(alert(), %{}) == [{:sound, "done"}]
  end

  test "OSC 9 text has no control characters and is capped" do
    a = %{alert(nil) | title: "a\e]0;x\a\nb\u009b", body: String.duplicate("z", 500)}
    [{:osc9, text}] = Alert.actions(a, props(:terminal))
    refute text =~ ~r/[\x00-\x1f\x7f\x{80}-\x{9f}]/u
    assert String.starts_with?(text, "a]0;xb: zz")
    assert String.length(text) == 200
  end
end
