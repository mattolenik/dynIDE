defmodule HerdrIntegration.RealKernelTest do
  @moduledoc """
  M3's exit drivers against the real server kernel (`HerdrServer.Native.*`, M1) with
  `/bin/sh` panes (`PS1='$ '`); the terminal client stays on its fakes (M2 not landed).
  Excluded by default: `mix test --only real_kernel` (the 20MB file goes to
  `HERDR_REAL_KERNEL_TMP`, default the system tmp dir). `setup_all` restarts herdr_server
  on the real kernel and restores the fake kernel afterwards.
  """
  use ExUnit.Case, async: false
  @moduletag :real_kernel
  @moduletag timeout: 120_000

  alias HerdrIntegration.Driver
  alias HerdrServer.Pane.Rows

  # SHELL is read in the VM (System.get_env); the rest must reach the child via :pane_env
  @pane_env [{"PS1", "$ "}, {"BASH_SILENCE_DEPRECATION_WARNING", "1"}]
  @real [
    vt: HerdrServer.Native.Vt,
    pty: HerdrServer.Native.Pty,
    keeper: HerdrServer.Native.Keeper
  ]
  # ~20MB of numbered lines, then END
  @lines 400_000

  setup_all do
    prev_kernel = Application.fetch_env!(:herdr_server, :kernel)
    prev_shell = System.get_env("SHELL")
    System.put_env("SHELL", "/bin/sh")
    Application.put_env(:herdr_server, :pane_env, @pane_env)
    restart_server(@real)

    on_exit(fn ->
      restart_server(prev_kernel)
      Application.delete_env(:herdr_server, :pane_env)
      if prev_shell, do: System.put_env("SHELL", prev_shell), else: System.delete_env("SHELL")
    end)

    {:ok, big: big_file()}
  end

  defp restart_server(kernel) do
    :ok = Application.stop(:herdr_server)
    Application.put_env(:herdr_server, :kernel, kernel)
    {:ok, _} = Application.ensure_all_started(:herdr_server)
  end

  setup do
    Driver.reset()
  end

  test "15 panes at 200x50: cat 20MB in one, a shell answers in another", %{big: big} do
    assert HerdrServer.Kernel.keeper() == HerdrServer.Native.Keeper
    client = Driver.start_client({200, 50})
    frames = Driver.trace_frames(client)
    scene = Driver.grow(client, 15)
    assert length(scene.panes) == 15
    [flood, typed | _] = Enum.map(scene.panes, & &1.id)

    for id <- [flood, typed],
        do: assert(Driver.wait_screen(client, &prompt?(scene, id, &1), 5000))

    :ok = Driver.reset_frames(frames)

    Driver.click(client, flood)
    Driver.type(client, "cat #{big}\r")
    Driver.click(client, typed)
    Driver.type(client, "echo hello-#{typed}\r")
    assert Driver.wait_screen(client, &line?(scene, typed, &1, "hello-#{typed}"), 5000)
    assert Driver.wait_screen(client, &line?(scene, flood, &1, "END"), 30_000)

    assert %{count: n, bad: []} = Driver.frame_stats(frames)
    assert n > 0
  end

  test "a second client at another size sees typing from the first and vice versa" do
    a = Driver.start_client({120, 40})
    b = Driver.start_client({80, 24})
    assert Driver.wait_screen(a, &prompt?(Driver.scene(a), 1, &1), 5000)

    Driver.type(a, "echo from-a\r")
    for c <- [a, b], do: assert(Driver.wait_screen(c, &line?(Driver.scene(c), 1, &1, "from-a")))

    Driver.type(b, "echo from-b\r")
    for c <- [a, b], do: assert(Driver.wait_screen(c, &line?(Driver.scene(c), 1, &1, "from-b")))

    assert Driver.scene(a).size == %{cols: 120, rows: 40}
    assert Driver.scene(b).size == %{cols: 80, rows: 24}
  end

  test "exit in a pane closes it" do
    client = Driver.start_client({120, 40})
    scene = Driver.grow(client, 2)
    [_, second] = Enum.map(scene.panes, & &1.id)
    assert Driver.wait_screen(client, &prompt?(scene, second, &1), 5000)
    Driver.click(client, second)
    Driver.type(client, "exit\r")

    assert Driver.wait_screen(client, fn _ -> length(Driver.scene(client).panes) == 1 end, 5000)
    assert Rows.kernel_id(second) == nil
  end

  defp rows(scene, id, screen) do
    scene.panes |> Enum.find(&(&1.id == id)) |> Map.fetch!(:rect) |> Driver.region(screen)
  end

  defp prompt?(scene, id, screen), do: Enum.any?(rows(scene, id, screen), &(&1 =~ ~r/^\$ /))

  # a whole row reads `text` (the shell's output, not the echoed command line)
  defp line?(scene, id, screen, text),
    do: Enum.any?(rows(scene, id, screen), &(String.trim_trailing(&1) == text))

  defp big_file do
    dir = System.get_env("HERDR_REAL_KERNEL_TMP", System.tmp_dir!())
    path = Path.join(dir, "herdr-real-kernel-#{System.unique_integer([:positive])}")

    lines =
      Stream.map(
        1..@lines,
        &"#{String.pad_leading("#{&1}", 8, "0")} #{String.duplicate("x", 40)}\n"
      )

    File.write!(path, Enum.to_list(lines) ++ ["END\n"])
    on_exit(fn -> File.rm(path) end)
    path
  end
end
