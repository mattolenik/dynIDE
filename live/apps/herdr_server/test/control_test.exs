defmodule HerdrServer.ControlTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Control

  # stands in for HerdrReload.Server: replies to {:rollback, n} like it
  defp fake_server(ids) do
    pid =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:rollback, n}} -> GenServer.reply(from, {:ok, Enum.take(ids, n)})
        end
      end)

    pid
  end

  defp path do
    dir = Path.join(System.tmp_dir!(), "hlc#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, "c.sock")
  end

  defp ask(path, line) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    :ok = :gen_tcp.send(s, line)
    {:ok, reply} = :gen_tcp.recv(s, 0, 2000)
    :gen_tcp.close(s)
    reply
  end

  test "rollback N calls the reload server and replies with the batch ids" do
    p = path()
    pid = start_supervised!({Control, path: p, server: fake_server([3, 2])})
    assert ask(p, "rollback 2\n") == "ok 3 2\n"
    assert ask(p, "frobnicate\n") == "error unknown command\n"
    :sys.replace_state(pid, &%{&1 | server: fake_server([])})
    assert ask(p, "rollback\n") == "ok none\n"
    stop_supervised!(Control)
    refute File.exists?(p)
  end

  test "a missing reload server is an error reply, not a crash" do
    p = path()
    start_supervised!({Control, path: p, server: :no_such_server})
    assert ask(p, "rollback 1\n") =~ ~r/^error /
    assert ask(p, "rollback 0\n") == "error unknown command\n"
  end

  test "a stale socket is replaced; a live one, a regular file or a dir is left alone" do
    p = path()
    File.mkdir_p!(Path.dirname(p))
    # a listener closed without unlinking leaves a stale socket file behind
    {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, p}])
    :gen_tcp.close(l)
    assert File.exists?(p)
    start_supervised!({Control, path: p, server: fake_server([1])})
    assert ask(p, "rollback 1\n") == "ok 1\n"
    assert :ignore = Control.init(path: p, server: nil)
    long = Path.join(Path.dirname(p), String.duplicate("x", 120))
    assert :ignore = Control.init(path: long, server: nil)

    file = Path.join(Path.dirname(p), "f.sock")
    File.write!(file, "keep")
    assert :ignore = Control.init(path: file, server: nil)
    assert File.read!(file) == "keep"
    dir = Path.join(Path.dirname(p), "d.sock")
    File.mkdir!(dir)
    assert :ignore = Control.init(path: dir, server: nil)
    assert File.dir?(dir)
  end

  test "a custom path's dir is neither created nor chmodded; an unwritable one is ignored" do
    p = path()
    dir = Path.dirname(p)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({Control, path: p, server: fake_server([])})
      end)

    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o755
    assert log =~ "group/other"
    stop_supervised!(Control)

    assert :ignore = Control.init(path: Path.join(dir, "missing/c.sock"), server: nil)
    refute File.exists?(Path.join(dir, "missing"))

    ro = Path.join(dir, "ro")
    File.mkdir!(ro)
    File.chmod!(ro, 0o500)
    on_exit(fn -> File.chmod(ro, 0o700) end)
    assert :ignore = Control.init(path: Path.join(ro, "c.sock"), server: nil)
  end

  test "the default state dir is created 0700, an existing open one is locked to 0700" do
    base = Path.join(System.tmp_dir!(), "hls#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    old = Map.take(System.get_env(), ["HERDR_LIVE_CONTROL", "XDG_STATE_HOME"])
    System.delete_env("HERDR_LIVE_CONTROL")
    System.put_env("XDG_STATE_HOME", base)

    on_exit(fn ->
      System.delete_env("XDG_STATE_HOME")
      System.put_env(old)
    end)

    start_supervised!({Control, server: fake_server([])})
    dir = Path.join(base, "herdr-live")
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    assert ask(Path.join(dir, "control.sock"), "rollback\n") == "ok none\n"
    stop_supervised!(Control)

    # an old launcher made it 0755; macOS ignores the socket's own 0600
    File.chmod!(dir, 0o755)
    start_supervised!({Control, server: fake_server([])})
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
  end

  test "a hung reload server times out with an error reply" do
    p = path()
    hung = spawn_link(fn -> Process.sleep(:infinity) end)
    start_supervised!({Control, path: p, server: hung, timeout_ms: 50})
    assert ask(p, "rollback 1\n") == "error timeout\n"
  end

  test "the default path honours HERDR_LIVE_CONTROL" do
    System.put_env("HERDR_LIVE_CONTROL", "/x/y.sock")
    on_exit(fn -> System.delete_env("HERDR_LIVE_CONTROL") end)
    assert Control.path() == "/x/y.sock"
  end
end
