defmodule HerdrServer.Native.PtyForegroundTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Native.{Pty, Vt}

  @env [{"PS1", "$ "}, {"ENV", ""}]

  defp spawn_sh(args) do
    {:ok, vt} = Vt.new(80, 24, 1000)
    {:ok, pty, os_pid} = Pty.spawn(vt, 1, "/bin/sh", args, @env, nil, 80, 24)
    on_exit(fn -> Pty.kill(pty, :kill) end)
    {pty, os_pid}
  end

  defp wait(f, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    cond do
      v = f.() -> v
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait(f, deadline)
    end
  end

  test "activity counts output while hidden" do
    {pty, _} = spawn_sh(["-c", "sleep 0.3; printf x; sleep 30"])
    :ok = Pty.set_hidden(pty, true)
    assert Pty.activity(pty) == 0
    assert wait(fn -> Pty.activity(pty) > 0 end)
  end

  test "at rest the foreground group is the shell" do
    {pty, os_pid} = spawn_sh([])
    assert Pty.foreground_pgid(pty) == os_pid
    assert %{pgid: ^os_pid, shell: true, processes: [_ | _]} = Pty.foreground_job(pty)
  end

  test "a running command is the foreground job" do
    {pty, os_pid} = spawn_sh(["-i"])
    # a PATH with GNU coreutils first would run `gsleep`
    :ok = Pty.write(pty, "PATH=/bin:/usr/bin; sleep 30\n")

    job =
      wait(fn ->
        job = Pty.foreground_job(pty)

        job && Enum.any?(job.processes, &(&1.name == "sleep" and &1.argv == ["sleep", "30"])) &&
          job
      end)

    assert %{shell: false, pgid: pgid} = job
    assert pgid != os_pid and Pty.foreground_pgid(pty) == pgid
    System.cmd("kill", ["-9", "-#{pgid}"], stderr_to_stdout: true)
  end
end
