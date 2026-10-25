defmodule HerdrCli.RelayTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Wire

  # Relay.run reads stdin/stdout through fd ports, so it runs in its own erl.
  defp start_relay(env, args \\ []) do
    elixir = Path.join(:code.lib_dir(:elixir), "ebin")
    cli = Path.join(:code.lib_dir(:herdr_cli), "ebin")
    scene = Path.join(:code.lib_dir(:herdr_scene), "ebin")
    erl = System.find_executable("erl")

    Port.open({:spawn_executable, erl}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
      args:
        ~w(-noinput -boot no_dot_erlang -pa #{elixir} -pa #{cli} -pa #{scene} -run Elixir.HerdrCli main_erl -extra attach-relay) ++
          args
    ])
  end

  setup do
    dir = Path.join("/tmp", "hrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, env: %{"HERDR_LIVE_API" => Path.join(dir, "api.sock"), "HOME" => dir}}
  end

  defp collect(port, acc \\ "") do
    receive do
      {^port, {:data, d}} -> collect(port, acc <> d)
      {^port, {:exit_status, s}} -> {s, acc}
    after
      15_000 -> flunk("relay did not exit; output #{inspect(acc)}")
    end
  end

  test "sends auth first, then relays both ways, exits 0 on socket close", %{dir: dir, env: env} do
    File.write!(Path.join(dir, "client.token"), "sekrit\n")

    {:ok, l} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        ifaddr: {:local, Path.join(dir, "client.sock")}
      ])

    port = start_relay(env)
    {:ok, s} = :gen_tcp.accept(l, 15_000)
    auth = IO.iodata_to_binary(Wire.encode({:auth, "sekrit"}))
    assert {:ok, ^auth} = :gen_tcp.recv(s, byte_size(auth), 5_000)

    Port.command(port, "to-server")
    assert {:ok, "to-server"} = :gen_tcp.recv(s, 9, 5_000)
    :ok = :gen_tcp.send(s, "to-client")
    :gen_tcp.close(s)
    assert {0, "to-client"} = collect(port)
  end

  test "exits 0 when stdin closes", %{dir: dir, env: env} do
    File.write!(Path.join(dir, "client.token"), "t")

    {:ok, l} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        ifaddr: {:local, Path.join(dir, "client.sock")}
      ])

    port = start_relay(env)
    {:ok, s} = :gen_tcp.accept(l, 15_000)
    {:ok, _} = :gen_tcp.recv(s, 0, 5_000)
    Port.close(port)
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 5_000)
  end

  test "no token: message on stderr, exit 1", %{env: env} do
    port = start_relay(env)
    {1, out} = collect(port)
    assert out =~ "no client token at"
  end
end
