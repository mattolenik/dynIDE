defmodule HerdrCliTest do
  use ExUnit.Case, async: true

  test "chars/2 decodes code points under a utf8 native name encoding" do
    assert HerdrCli.chars(~c"plain", :utf8) == "plain"
    assert HerdrCli.chars([233, ?x], :utf8) == "éx"
    assert HerdrCli.chars([0x1F600], :utf8) == "\u{1F600}"
    # code points that happen to spell valid UTF-8 bytes stay those code points
    assert HerdrCli.chars([0xC3, 0xA9], :utf8) == "Ã©"
  end

  test "chars/2 takes raw bytes under a latin1 native name encoding" do
    assert HerdrCli.chars(:binary.bin_to_list("é api"), :latin1) == "é api"
  end

  test "a usage error exits 2 without touching the socket" do
    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert HerdrCli.run(["pane", "split", "--direction", "left"], %{}) == 2
           end) =~ "usage: herdr-live pane split"
  end

  # main/1 halts, so it runs in its own erl like bin/herdr-live starts it.
  test "a crash prints nothing on stdout and exits 1" do
    elixir = Path.join(:code.lib_dir(:elixir), "ebin")
    cli = Path.join(:code.lib_dir(:herdr_cli), "ebin")

    # an argv that is not a list makes run/2 raise inside main/1's worker process
    {out, code} =
      System.cmd(
        "erl",
        ~w(-noinput -boot no_dot_erlang -pa #{elixir} -pa #{cli} -eval) ++
          ["'Elixir.HerdrCli':main(not_a_list)."],
        env: [{"ERL_CRASH_DUMP_SECONDS", "0"}]
      )

    assert code == 1
    assert out == ""
  end
end
