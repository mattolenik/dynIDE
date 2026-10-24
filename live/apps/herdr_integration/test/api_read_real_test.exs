defmodule HerdrIntegration.ApiReadRealTest do
  @moduledoc """
  `pane.run`, `pane.wait_for_output` and `pane.read` through the JSON socket against the
  real kernel (pins the `{:rows, ..}` index semantics of `Vt.read_text/2`). Excluded by
  default: `mix test --only real_kernel`.
  """
  use ExUnit.Case, async: false
  @moduletag :real_kernel
  @moduletag timeout: 60_000

  alias HerdrServer.Api.Listener
  alias HerdrServer.App.Store

  @real [
    vt: HerdrServer.Native.Vt,
    pty: HerdrServer.Native.Pty,
    keeper: HerdrServer.Native.Keeper
  ]

  setup_all do
    prev_kernel = Application.fetch_env!(:herdr_server, :kernel)
    prev_shell = System.get_env("SHELL")
    System.put_env("SHELL", "/bin/sh")
    Application.put_env(:herdr_server, :pane_env, [{"PS1", "$ "}])

    on_exit(fn ->
      restart(prev_kernel)
      Application.delete_env(:herdr_server, :pane_env)
      if prev_shell, do: System.put_env("SHELL", prev_shell), else: System.delete_env("SHELL")
    end)

    restart(@real)
    :ok
  end

  defp restart(kernel) do
    _ = Application.stop(:herdr_server)
    Application.put_env(:herdr_server, :kernel, kernel)
    {:ok, _} = Application.ensure_all_started(:herdr_server)
  end

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    dir = Path.join(System.tmp_dir!(), "har#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "a.sock")
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})

    {:ok, s} =
      :gen_tcp.connect({:local, path}, 0, [
        :binary,
        packet: :line,
        active: false,
        buffer: 1_048_576
      ])

    %{s: s}
  end

  defp call(s, method, params) do
    req = JSON.encode!(%{"id" => "t", "method" => method, "params" => params})
    :ok = :gen_tcp.send(s, [req, "\n"])
    {:ok, line} = :gen_tcp.recv(s, 0, 30_000)
    JSON.decode!(line)
  end

  test "run, wait_for_output and read recent through the socket", %{s: s} do
    assert %{"result" => _} = call(s, "workspace.list", %{})
    p = %{"pane_id" => "p1"}

    assert %{"result" => _} =
             call(s, "pane.run", Map.put(p, "command", "printf 'r%s\\n' 1 2 3"))

    assert %{"result" => %{"line" => "r3"}} =
             call(
               s,
               "pane.wait_for_output",
               Map.merge(p, %{"match" => "r3", "timeout_ms" => 20_000})
             )

    assert %{"result" => %{"text" => text}} =
             call(s, "pane.read", Map.merge(p, %{"source" => "recent", "lines" => 3}))

    # the prompt may already be back below r3
    assert text =~ ~r/\Ar1\nr2\nr3\z|\Ar2\nr3\n\$\z/
    assert length(String.split(text, "\n")) <= 3
  end
end
