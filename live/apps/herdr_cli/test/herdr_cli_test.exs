defmodule HerdrCliTest do
  use ExUnit.Case, async: true

  test "chars/1 decodes argv bytes (latin1 filename mode) and code points (utf8 mode)" do
    assert HerdrCli.chars(~c"plain") == "plain"
    assert HerdrCli.chars(:binary.bin_to_list("é api")) == "é api"
    assert HerdrCli.chars([233, ?x]) == "éx"
    assert HerdrCli.chars([0x1F600]) == "\u{1F600}"
  end

  test "a usage error exits 2 without touching the socket" do
    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert HerdrCli.run(["pane", "split", "--direction", "left"], %{}) == 2
           end) =~ "usage: herdr-live pane split"
  end
end
