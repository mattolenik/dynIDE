defmodule HerdrServer.Native.PtyHandoffTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Native.{Pty, Vt}

  @env [{"PS1", "$ "}, {"ENV", ""}]

  defp spawn_sh(id, args \\ []) do
    {:ok, vt} = Vt.new(80, 24, 1000)
    {:ok, pty, os_pid} = Pty.spawn(vt, id, "/bin/sh", args, @env, nil, 80, 24)
    {pty, os_pid}
  end

  defp alive?(os_pid), do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"]))

  defp wait_text(vt, pred, deadline) do
    cond do
      pred.(Vt.read_text(vt, :screen)) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        receive do
          {:damage, _, _} -> :ok
        after
          50 -> :ok
        end

        wait_text(vt, pred, deadline)
    end
  end

  test "dup, freeze, release, adopt keeps the child" do
    {pty, os_pid} = spawn_sh(98)
    {:ok, fd} = Pty.dup_fd(pty)
    assert Pty.freeze(pty) == ""
    assert Pty.release(pty) == :ok
    assert Pty.thaw(pty) == {:error, :released}

    {:ok, vt2} = Vt.new(80, 24, 1000)
    assert {:ok, pty2} = Pty.adopt(vt2, 99, fd, os_pid, false, nil, nil)
    assert :ok = Pty.subscribe(pty2, self())
    assert Pty.write(pty2, "echo ok-$((90+9))\n") == :ok
    assert_receive {:damage, 99, _}, 2000
    deadline = System.monotonic_time(:millisecond) + 3000
    assert wait_text(vt2, &(&1 =~ "ok-99"), deadline)
    assert %{os_pid: ^os_pid, adopted: true, exited: nil} = Pty.info(pty2)
    assert alive?(os_pid)

    assert Pty.write(pty2, "exit\n") == :ok
    assert_receive {:exit, 99, :unknown}, 5000
  end

  test "fd resource is single use" do
    {pty, os_pid} = spawn_sh(97)
    {:ok, fd} = Pty.dup_fd(pty)
    {:ok, vt} = Vt.new(80, 24, 1000)
    assert {:ok, adopted} = Pty.adopt(vt, 96, fd, os_pid, false, "t", "p")
    assert %{title: "t", pwd: "p"} = Pty.info(adopted)
    assert Pty.adopt(vt, 95, fd, os_pid, false, nil, nil) == {:error, :consumed}
    assert Pty.release(pty) == {:error, :not_frozen}
    Pty.kill(pty, :kill)
  end

  test "adopt with another start time is exited and never signalled" do
    {pty, os_pid} = spawn_sh(93, ["-c", "sleep 30"])
    assert %{start_time: st} = Pty.info(pty)
    assert is_integer(st)
    {:ok, fd} = Pty.dup_fd(pty)
    Pty.freeze(pty)
    :ok = Pty.release(pty)

    {:ok, vt} = Vt.new(80, 24, 1000)
    # the pid now names a different process (recycled)
    assert {:ok, adopted} = Pty.adopt(vt, 92, fd, os_pid, false, nil, nil, st + 1)
    :ok = Pty.subscribe(adopted, self())
    assert_receive {:exit, 92, :unknown}, 5000
    :ok = Pty.kill(adopted, :kill)
    Process.sleep(100)
    assert alive?(os_pid)
    System.cmd("kill", ["-9", "#{os_pid}"])
  end

  test "info reports title after OSC 2" do
    {pty, _} = spawn_sh(94, ["-c", "printf '\\033]2;handoff-title\\007'; sleep 30"])
    :ok = Pty.subscribe(pty, self())
    assert_receive {:title, 94, "handoff-title"}, 2000
    assert %{title: "handoff-title", adopted: false, exited: nil} = Pty.info(pty)
    Pty.kill(pty, :kill)
    assert_receive {:exit, 94, {:signal, 9}}, 5000
    assert %{exited: {:signal, 9}} = Pty.info(pty)
  end
end
