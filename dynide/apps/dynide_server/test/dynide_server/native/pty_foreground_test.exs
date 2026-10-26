defmodule DynideServer.Native.PtyForegroundTest do
  use ExUnit.Case, async: false

  alias DynideServer.Detect.Poller
  alias DynideServer.Native.{Pty, Vt}

  @env [{"PS1", "$ "}, {"ENV", ""}]

  defp spawn_sh(args) do
    {_vt, pty, os_pid} = spawn_vt(args)
    {pty, os_pid}
  end

  defp spawn_vt(args) do
    {:ok, vt} = Vt.new(80, 24, 1000)
    {:ok, pty, os_pid} = Pty.spawn(vt, 1, "/bin/sh", args, @env, nil, 80, 24)
    on_exit(fn -> Pty.kill(pty, :kill) end)
    {vt, pty, os_pid}
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

  test "the detection source is the bottom screen rows, wherever the viewport is" do
    script = "i=1; while [ $i -le 100 ]; do echo line$i; i=$((i+1)); done; sleep 30"
    {vt, _pty, _} = spawn_vt(["-c", script])

    assert wait(fn -> (Poller.source(Vt, vt) || "") =~ ~r/^line100$/m end)
    src = Poller.source(Vt, vt)
    refute src =~ ~r/^line1$/m
    assert Vt.scrollbar(vt).total > 100

    :ok = Vt.scroll_to(vt, 0)
    assert wait(fn -> Vt.read_text(vt, :viewport) =~ ~r/^line1$/m end)
    assert Poller.source(Vt, vt) == src
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
    # kills the last job group seen, also when an assertion fails
    seen = :atomics.new(1, signed: false)

    on_exit(fn ->
      pgid = :atomics.get(seen, 1)
      if pgid > 0, do: System.cmd("kill", ["-9", "-#{pgid}"], stderr_to_stdout: true)
    end)

    job =
      wait(fn ->
        job = Pty.foreground_job(pty)
        if job && not job.shell, do: :atomics.put(seen, 1, job.pgid)

        job && Enum.any?(job.processes, &(&1.name == "sleep" and &1.argv == ["sleep", "30"])) &&
          job
      end)

    assert %{shell: false, pgid: pgid} = job
    assert pgid != os_pid and Pty.foreground_pgid(pty) == pgid
  end
end
