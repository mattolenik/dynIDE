defmodule DynideTerm.Client.Term.AlertTest do
  use ExUnit.Case, async: true

  alias DynideTerm.Client.Term.Alert

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
    assert Alert.actions(alert(), props(:herdr)) == [{:sound, :done}]
    assert Alert.actions(alert(:request), props(:herdr)) == [{:sound, :request}]
    assert Alert.actions(alert(nil), props(:herdr)) == []
  end

  test "terminal delivery writes OSC 9 with title and body" do
    assert Alert.actions(alert(), props(:terminal)) == [
             {:write, "\e]9;pi finished: w · 1\e\\"},
             {:sound, :done}
           ]
  end

  test "terminal delivery follows the client's terminal: kitty OSC 99, tmux-wrapped" do
    env = %{"KITTY_WINDOW_ID" => "1", "TMUX" => "/tmp/t,1,0"}

    assert [{:write, "\ePtmux;\e\e]99;i=1:d=0;pi finished" <> _}, _] =
             Alert.actions(alert(), props(:terminal), env)
  end

  test "system delivery asks for a desktop notification" do
    assert Alert.actions(alert(), props(:system)) == [
             {:system, "pi finished", "w · 1"},
             {:sound, :done}
           ]
  end

  test "off delivers nothing but the sound" do
    assert Alert.actions(alert(), props(:off)) == [{:sound, :done}]
  end

  test "a disabled sound is silent" do
    assert Alert.actions(alert(), props(:terminal, false)) == [
             {:write, "\e]9;pi finished: w · 1\e\\"}
           ]
  end

  test "a sound-only alert (no title) gets no notification" do
    a = %{alert(:request) | title: nil, body: nil}
    assert Alert.actions(a, props(:terminal)) == [{:sound, :request}]
    assert Alert.actions(a, props(:system)) == [{:sound, :request}]
  end

  test "missing props: herdr delivery, sound on" do
    assert Alert.actions(alert(), %{}) == [{:sound, :done}]
  end

  test "notification text has no control characters and is capped" do
    a = %{alert(nil) | title: "a\e]0;x\a\nb\u009b", body: String.duplicate("z", 500)}
    [{:system, title, body}] = Alert.actions(a, props(:system))
    refute title <> body =~ ~r/[\x00-\x1f\x7f\x{80}-\x{9f}]/u
    assert title == "a]0;x b"
    assert String.length(body) == 200
  end
end
