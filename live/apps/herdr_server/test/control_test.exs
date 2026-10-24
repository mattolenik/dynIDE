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
    assert File.stat!(Path.dirname(p)).mode |> Bitwise.band(0o777) == 0o700
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

  test "a stale socket file is replaced; a live one is left alone" do
    p = path()
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, "")
    start_supervised!({Control, path: p, server: fake_server([1])})
    assert ask(p, "rollback 1\n") == "ok 1\n"
    assert :ignore = Control.init(path: p, server: nil)
    long = Path.join(Path.dirname(p), String.duplicate("x", 120))
    assert :ignore = Control.init(path: long, server: nil)
  end

  test "the default path honours HERDR_LIVE_CONTROL" do
    System.put_env("HERDR_LIVE_CONTROL", "/x/y.sock")
    on_exit(fn -> System.delete_env("HERDR_LIVE_CONTROL") end)
    assert Control.path() == "/x/y.sock"
  end
end
