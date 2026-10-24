defmodule HerdrServer.Native.PtyTest do
  use ExUnit.Case, async: false

  alias HerdrScene.Cell
  alias HerdrServer.Native
  alias HerdrServer.Native.{Pty, Vt}

  @env [{"PS1", "$ "}, {"ENV", ""}]

  defp text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))

  defp spawn_sh(id, args \\ []) do
    {:ok, vt} = Vt.new(80, 24, 1000)
    {:ok, pty, os_pid} = Pty.spawn(vt, id, "/bin/sh", args, @env, nil, 80, 24)
    assert is_integer(os_pid) and os_pid > 0
    {vt, pty}
  end

  defp poll_rows(vt, pred, deadline) do
    {_, rows} = Vt.dirty_rows(vt)

    cond do
      Enum.any?(rows, fn {_, r} -> pred.(text(r)) end) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(20)
        poll_rows(vt, pred, deadline)
    end
  end

  test "exit criterion 1: echo then exit" do
    {vt, pty} = spawn_sh(1)
    assert Pty.subscribe(pty, self()) == :ok
    # `h''i` keeps the echoed command line from matching. Typeahead can put the
    # output after the prompt (dash on Linux), so "hi" may follow "$ ".
    assert Pty.write(pty, "echo h''i\n") == :ok
    assert_receive {:damage, 1, _}, 2000
    deadline = System.monotonic_time(:millisecond) + 2000
    assert poll_rows(vt, &(String.trim_trailing(&1) =~ ~r/(^|\$ )hi$/), deadline)
    assert Pty.write(pty, ["ex", ~c"it", ?\n]) == :ok
    assert_receive {:exit, 1, 0}, 5000
    assert Pty.write(pty, "x") == {:error, :closed}
  end

  test "resubscribe after the subscriber dies gets full damage" do
    {vt, pty} = spawn_sh(2)
    test = self()

    first =
      spawn(fn ->
        :ok = Pty.subscribe(pty, self())
        receive do: ({:damage, 2, _} -> :ok)
        Vt.dirty_rows(vt)
        {_, []} = Vt.dirty_rows(vt)
        send(test, :drained)
        Process.sleep(:infinity)
      end)

    assert_receive :drained, 2000
    Process.exit(first, :kill)

    second =
      spawn(fn ->
        :ok = Pty.subscribe(pty, self())
        receive do: ({:damage, 2, _} -> send(test, {:rows, Vt.dirty_rows(vt)}))
      end)

    assert_receive {:rows, {_, rows}}, 2000
    assert length(rows) == 24
    Process.exit(second, :kill)
    Pty.kill(pty, :kill)
  end

  test "exit before subscribe is still delivered" do
    {_vt, pty} = spawn_sh(3, ["-c", "exit 5"])
    Process.sleep(300)
    assert Pty.subscribe(pty, self()) == :ok
    assert_receive {:damage, 3, _}
    assert_receive {:exit, 3, 5}, 2000
    refute_receive {:exit, 3, _}, 200
  end

  test "resubscribing after exit does not resend the exit" do
    {_vt, pty} = spawn_sh(8, ["-c", "exit 0"])
    :ok = Pty.subscribe(pty, self())
    assert_receive {:exit, 8, 0}, 2000
    assert Pty.subscribe(pty, self()) == :ok
    assert_receive {:damage, 8, _}
    refute_receive {:exit, 8, _}, 200
  end

  test "kill reports the signal, resize and set_hidden work" do
    {_vt, pty} = spawn_sh(4)
    :ok = Pty.subscribe(pty, self())
    assert Pty.resize(pty, 100, 30, {8, 16}) == :ok
    assert Pty.resize(pty, 100, 30, nil) == :ok
    assert Pty.set_hidden(pty, true) == :ok
    assert Pty.set_hidden(pty, false) == :ok
    assert Pty.kill(pty, :kill) == :ok
    assert_receive {:exit, 4, {:signal, 9}}, 2000
  end

  test "reader panic reports exit and leaves the vm up" do
    {vt, pty} = spawn_sh(5)
    :ok = Pty.subscribe(pty, self())
    assert Native.test_inject_reader_panic(pty) == :ok
    Pty.write(pty, "echo boom\n")
    assert_receive {:exit, 5, {:panic, reason}}, 2000
    assert is_binary(reason)
    refute_receive {:exit, 5, _}, 200
    assert {_, rows} = Vt.full_rows(vt)
    assert length(rows) == 24
    assert Process.alive?(Process.whereis(HerdrServer.Supervisor))
  end

  test "backpressure for a child that is not reading" do
    {_vt, pty} = spawn_sh(6, ["-c", "sleep 30"])
    chunk = :binary.copy("x", 64 * 1024)

    result =
      Enum.reduce_while(1..200, :ok, fn _, _ ->
        case Pty.write(pty, chunk) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)

    assert result == {:error, :backpressure}
    Pty.kill(pty, :kill)
  end

  test "invalid arguments raise" do
    {vt, pty} = spawn_sh(7)
    assert_raise ArgumentError, fn -> Pty.kill(pty, :bogus) end

    for {cols, rows} <- [{0, 24}, {80, 0}, {65_536, 24}, {80, 1.5}, {nil, 24}] do
      assert_raise ArgumentError, ~r/1\.\.65535/, fn -> Vt.new(cols, rows, 100) end
      assert_raise ArgumentError, ~r/1\.\.65535/, fn -> Vt.resize(vt, cols, rows, nil) end
      assert_raise ArgumentError, ~r/1\.\.65535/, fn -> Pty.resize(pty, cols, rows, nil) end

      assert_raise ArgumentError, ~r/1\.\.65535/, fn ->
        Pty.spawn(vt, 70, "/bin/sh", [], @env, nil, cols, rows)
      end
    end

    assert Vt.resize(vt, 65_535, 1, nil) == :ok
    Pty.kill(pty, :kill)
  end

  test "a write over 1 MiB is too large" do
    {_vt, pty} = spawn_sh(9, ["-c", "sleep 30"])
    assert Pty.write(pty, :binary.copy("x", 1024 * 1024 + 1)) == {:error, :too_large}
    assert Pty.write(pty, :binary.copy("x", 1024 * 1024)) == :ok
    Pty.kill(pty, :kill)
  end

  test "spawn errors" do
    {:ok, vt} = Vt.new(80, 24, 100)
    # portable-pty checks the executable itself and reports errno only in the message.
    assert {:error, {:spawn, msg}} = Pty.spawn(vt, 10, "/nonexistent/xyz", [], [], nil, 80, 24)
    assert msg =~ "ENOENT"
    assert {:error, {:spawn, _}} = Pty.spawn(vt, 11, "/", [], [], nil, 80, 24)
  end

  test "erts coexistence: System.cmd and kernel panes reap independently" do
    alias HerdrServer.Native.Keeper

    cmds =
      Task.async(fn ->
        for _ <- 1..20, do: System.cmd("true", [])
      end)

    ids =
      for n <- 1..10 do
        {:ok, id} =
          Keeper.open(%{
            cmd: "/bin/sh",
            args: ["-c", "exit #{n}"],
            env: [],
            cwd: nil,
            cols: 80,
            rows: 24,
            max_scrollback: 100,
            subscriber: self()
          })

        {id, n}
      end

    for {id, n} <- ids, do: assert_receive({:exit, ^id, ^n}, 10_000)
    assert Enum.all?(Task.await(cmds, 30_000), fn {_, status} -> status == 0 end)
    for {id, _} <- ids, do: Keeper.close(id)
  end
end
