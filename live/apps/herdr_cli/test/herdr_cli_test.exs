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

  test "a confirmed plugin install waits as long as the server's git and builds" do
    assert HerdrCli.timeout("plugin.install", %{"source" => "o/r", "yes" => true}) == :infinity
    assert HerdrCli.timeout("plugin.install", %{"source" => "o/r"}) == 60_000
    assert HerdrCli.timeout("plugin.update", %{"yes" => true}) == :infinity
    assert HerdrCli.timeout("plugin.update", %{}) == 60_000
    assert HerdrCli.timeout("plugin.list", %{}) == 60_000
  end

  test "an unreadable --file exits 1 with a message on stderr" do
    err =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert HerdrCli.run(~w(agent explain --file /nonexistent/x --agent a), %{}) == 1
      end)

    assert err =~ "cannot read /nonexistent/x"
  end

  test "a --file over 1 MiB exits 1 before reaching the socket" do
    path = Path.join(System.tmp_dir!(), "hcli-big-#{System.unique_integer([:positive])}")
    File.write!(path, :binary.copy("x", 1_048_577))
    on_exit(fn -> File.rm(path) end)

    err =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert HerdrCli.run(["agent", "explain", "--file", path, "--agent", "a"], %{}) == 1
      end)

    assert err =~ "is 1048577 bytes, over the 1048576 byte limit"
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
    dir = Path.join(System.tmp_dir!(), "hcli-crash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    stderr = Path.join(dir, "stderr")

    # an argv that is not a list makes run/2 raise inside main/1's worker process;
    # stderr (the crash report) goes to a file, not into this test run's output
    {out, code} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(exec erl -noinput -boot no_dot_erlang -pa "$1" -pa "$2" -eval "$3" 2>"$4"),
          "sh",
          elixir,
          cli,
          "'Elixir.HerdrCli':main(not_a_list).",
          stderr
        ],
        env: [{"ERL_CRASH_DUMP_SECONDS", "0"}]
      )

    assert code == 1
    assert out == ""
    assert File.read!(stderr) =~ "herdr-live: internal error"
  end

  test "help and --help print usage on stdout and exit 0" do
    for arg <- ["help", "--help"] do
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
                   assert HerdrCli.run([arg], %{}) == 0
                 end) == ""
        end)

      assert out =~ "usage: herdr-live <verb>"
    end
  end

  test "an event stream the server closes exits 1 with a message on stderr" do
    dir = Path.join(System.tmp_dir!(), "hcli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "api.sock")
    {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(l, 10_000)
      :ok = :inet.setopts(s, packet: :line)
      {:ok, _line} = :gen_tcp.recv(s, 0, 10_000)
      ack = ~s({"id":"cli","result":{"type":"subscription_started","subscriptions":1}}\n)
      ev = ~s({"event":"tab.closed","data":{"tab_id":"w1:t2","workspace_id":"w1"}}\n)
      :ok = :gen_tcp.send(s, [ack, ev])
      :gen_tcp.close(s)
    end)

    err =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        out =
          ExUnit.CaptureIO.capture_io(fn ->
            assert HerdrCli.run(["events", "subscribe", "tab.closed"], %{"HERDR_LIVE_API" => path}) ==
                     1
          end)

        assert out =~ "tab.closed"
      end)

    assert err == "herdr-live: stream closed by server\n"
  end
end
