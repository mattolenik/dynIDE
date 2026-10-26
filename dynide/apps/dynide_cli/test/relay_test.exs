defmodule DynideCli.RelayTest do
  use ExUnit.Case, async: true

  alias DynideScene.Wire

  # Relay.run reads stdin/stdout through fd ports, so it runs in its own erl.
  defp start_relay(env, args \\ [], merge \\ [:stderr_to_stdout]) do
    elixir = Path.join(:code.lib_dir(:elixir), "ebin")
    cli = Path.join(:code.lib_dir(:dynide_cli), "ebin")
    scene = Path.join(:code.lib_dir(:dynide_scene), "ebin")
    erl = System.find_executable("erl")

    Port.open(
      {:spawn_executable, erl},
      merge ++
        [
          :binary,
          :exit_status,
          env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
          args:
            ~w(-noinput -boot no_dot_erlang -pa #{elixir} -pa #{cli} -pa #{scene} -run Elixir.DynideCli main_erl -extra attach-relay) ++
              args
        ]
    )
  end

  setup do
    dir = Path.join("/tmp", "hrl-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, env: %{"DYNIDE_API" => Path.join(dir, "api.sock"), "HOME" => dir}}
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

  test "an empty token file is no token", %{dir: dir, env: env} do
    File.write!(Path.join(dir, "client.token"), " \n")
    {1, out} = collect(start_relay(env))
    assert out =~ "no client token at"
  end

  test "attach-relay --help prints usage without connecting", %{env: env} do
    port = start_relay(env, ["--help"])
    assert {0, "usage: dynide attach-relay" <> _} = collect(port)
  end

  defp listen(dir, token) do
    File.write!(Path.join(dir, "client.token"), token)

    {:ok, l} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        ifaddr: {:local, Path.join(dir, "client.sock")}
      ])

    l
  end

  test "1 MiB each way arrives byte for byte; stdout carries only relayed bytes", %{
    dir: dir,
    env: env
  } do
    l = listen(dir, "t")
    port = start_relay(env, [], [])
    {:ok, s} = :gen_tcp.accept(l, 15_000)
    {:ok, _} = :gen_tcp.recv(s, byte_size(IO.iodata_to_binary(Wire.encode({:auth, "t"}))), 5_000)
    up = :crypto.strong_rand_bytes(1_048_576)
    down = :crypto.strong_rand_bytes(1_048_576)
    Port.command(port, up)
    :ok = :gen_tcp.send(s, down)
    assert {:ok, ^up} = :gen_tcp.recv(s, byte_size(up), 15_000)
    :gen_tcp.close(s)
    assert {0, ^down} = collect(port)
  end

  test "a payload followed by close is fully written to stdout", %{dir: dir, env: env} do
    l = listen(dir, "t")
    port = start_relay(env, [], [])
    {:ok, s} = :gen_tcp.accept(l, 15_000)
    big = :crypto.strong_rand_bytes(6 * 1_048_576)
    :ok = :gen_tcp.send(s, big)
    :gen_tcp.close(s)
    assert {0, ^big} = collect(port)
  end

  test "exits 0 without an error when its stdout reader goes away", %{dir: dir, env: env} do
    l = listen(dir, "t")
    elixir = Path.join(:code.lib_dir(:elixir), "ebin")
    cli = Path.join(:code.lib_dir(:dynide_cli), "ebin")
    scene = Path.join(:code.lib_dir(:dynide_scene), "ebin")
    err = Path.join(dir, "err")
    st = Path.join(dir, "st")

    relay =
      "erl -noinput -boot no_dot_erlang -pa #{elixir} -pa #{cli} -pa #{scene} " <>
        "-run Elixir.DynideCli main_erl -extra attach-relay"

    # stdin stays open (the port), stdout's reader exits after 10 bytes
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
        args: ["-c", "(#{relay} 2>#{err}; echo $? >#{st}) | head -c 10 >/dev/null"]
      ])

    {:ok, s} = :gen_tcp.accept(l, 15_000)
    chunk = :binary.copy("x", 65_536)
    Stream.repeatedly(fn -> :gen_tcp.send(s, chunk) end) |> Enum.find(&(&1 != :ok))
    assert_receive {^port, {:exit_status, _}}, 15_000
    assert {"0\n", ""} == {File.read!(st), File.read!(err)}
  end
end
