defmodule HerdrTerm.Client.Term.NotifyTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Client.Term.Notify

  test "backend detection table" do
    for {env, want} <- [
          {%{"TERM_PROGRAM" => "ghostty"}, :osc9},
          {%{"TERM_PROGRAM" => "iTerm.app"}, :osc9},
          {%{"TERM_PROGRAM" => "WezTerm", "KITTY_WINDOW_ID" => "1"}, :osc9},
          {%{"KITTY_WINDOW_ID" => "3", "TERM" => "xterm-256color"}, :osc99},
          {%{"KITTY_WINDOW_ID" => "", "TERM" => "xterm-kitty"}, :osc99},
          {%{"TERM" => "xterm-ghostty"}, :osc9},
          {%{"TERM" => "wezterm"}, :osc9},
          {%{"TERM_PROGRAM" => "Apple_Terminal"}, :osc9},
          {%{}, :osc9}
        ],
        do: assert(Notify.backend(env) == want, inspect(env))

    assert Notify.tmux?(%{"TMUX" => "/tmp/tmux-1/default,1,0"})
    refute Notify.tmux?(%{"TMUX" => ""}) or Notify.tmux?(%{})
  end

  test "OSC 9 and OSC 99 bytes (herdr terminal_notify.rs)" do
    assert Notify.sequence(:osc9, "t", "b", false) == "\e]9;t: b\e\\"
    assert Notify.sequence(:osc9, "t", nil, false) == "\e]9;t\e\\"
    assert Notify.sequence(:osc99, "t", "", false) == "\e]99;;t\e\\"

    assert Notify.sequence(:osc99, "pi finished", "ws · 1", false) ==
             "\e]99;i=1:d=0;pi finished\e\\\e]99;i=1:p=body;ws · 1\e\\"
  end

  test "tmux passthrough wraps and doubles ESC" do
    assert Notify.wrap_tmux("\e]9;hi\e\\") == "\ePtmux;\e\e]9;hi\e\e\\\e\\"
    assert Notify.sequence(:osc9, "hi", nil, true) == "\ePtmux;\e\e]9;hi\e\e\\\e\\"
  end
end
