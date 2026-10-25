defmodule HerdrCli.ClientTest do
  use ExUnit.Case, async: true

  alias HerdrCli.Client

  @moduletag :tmp_dir

  # A short socket path: sun_path is 104 bytes on macOS and tmp_dir paths are long.
  defp sock_path do
    dir = Path.join(System.tmp_dir!(), "hcli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "api.sock")
  end

  defp listen(path) do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    l
  end

  # Answers each request line with `reply.(decoded_request)` lines.
  defp serve(l, reply) do
    {:ok, s} = :gen_tcp.accept(l, 10_000)
    :ok = :inet.setopts(s, packet: :line)
    {:ok, line} = :gen_tcp.recv(s, 0, 10_000)
    for out <- reply.(JSON.decode!(line)), do: :gen_tcp.send(s, out)
    :gen_tcp.close(s)
  end

  describe "socket_path/1" do
    test "HERDR_LIVE_API wins, empty counts as unset" do
      assert Client.socket_path(%{"HERDR_LIVE_API" => "/x/a.sock", "HOME" => "/h"}) ==
               "/x/a.sock"

      assert Client.socket_path(%{"HERDR_LIVE_API" => "", "HOME" => "/h"}) ==
               "/h/.local/state/herdr-live/api.sock"

      assert Client.socket_path(%{"XDG_STATE_HOME" => "/s", "HOME" => "/h"}) ==
               "/s/herdr-live/api.sock"

      assert Client.socket_path(%{"XDG_STATE_HOME" => "", "HOME" => "/h"}) ==
               "/h/.local/state/herdr-live/api.sock"
    end
  end

  test "retries a missing socket" do
    path = sock_path()
    test = self()

    spawn_link(fn ->
      Process.sleep(300)
      l = listen(path)
      send(test, :listening)
      {:ok, s} = :gen_tcp.accept(l, 10_000)
      send(test, :accepted)
      Process.sleep(1000)
      :gen_tcp.close(s)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:ok, _sock} = Client.connect(path, 5000)
    assert System.monotonic_time(:millisecond) - started >= 250
    assert_receive :listening
    assert_receive :accepted, 5000
  end

  test "retries a refused socket (a stale file nobody listens on)" do
    path = sock_path()
    l = listen(path)
    # closing a listener leaves the file behind: connects get econnrefused
    :gen_tcp.close(l)
    assert File.exists?(path)

    spawn_link(fn ->
      Process.sleep(300)
      File.rm(path)
      l2 = listen(path)
      {:ok, _s} = :gen_tcp.accept(l2, 10_000)
      Process.sleep(1000)
    end)

    assert {:ok, _sock} = Client.connect(path, 5000)
  end

  test "gives up after retry_ms" do
    path = sock_path()
    started = System.monotonic_time(:millisecond)
    assert {:error, :enoent} = Client.connect(path, 200)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 150 and elapsed < 5000
  end

  test "call sends one request line and returns the decoded reply" do
    path = sock_path()
    l = listen(path)
    test = self()

    spawn_link(fn ->
      serve(l, fn req ->
        send(test, {:req, req})
        [~s({"id":"cli","result":{"type":"pong","version":"0.1.0","gen":1}}\n)]
      end)
    end)

    {:ok, s} = Client.connect(path, 1000)
    assert {:ok, %{"result" => %{"type" => "pong", "gen" => 1}}} = Client.call(s, "ping", %{})
    assert_receive {:req, %{"id" => "cli:ping", "method" => "ping", "params" => %{}}}
  end

  test "lines longer than the socket buffer arrive whole" do
    path = sock_path()
    l = listen(path)
    text = String.duplicate("x", 3_000_000)

    spawn_link(fn ->
      serve(l, fn _ ->
        [JSON.encode!(%{id: "cli", result: %{type: "pane_read", text: text}}) <> "\n"]
      end)
    end)

    {:ok, s} = Client.connect(path, 1000)
    assert {:ok, %{"result" => %{"text" => ^text}}} = Client.call(s, "pane.read", %{})
  end

  test "stream yields each line after the ack until the server closes" do
    path = sock_path()
    l = listen(path)

    spawn_link(fn ->
      serve(l, fn _ ->
        [
          ~s({"id":"cli","result":{"type":"subscription_started","subscriptions":1}}\n),
          ~s({"event":"pane.created","data":{"pane_id":"p2"}}\n{"event":"pane.closed",),
          ~s("data":{"pane_id":"p2"}}\n)
        ]
      end)
    end)

    {:ok, s} = Client.connect(path, 1000)

    assert {:ok, %{"result" => %{"type" => "subscription_started"}}} =
             Client.call(s, "events.subscribe", %{})

    assert {:ok, %{"event" => "pane.created"}} = Client.next(s)
    assert {:ok, %{"event" => "pane.closed"}} = Client.next(s)
    assert :eof = Client.next(s)
  end

  test "a closed connection before a reply is an error" do
    path = sock_path()
    l = listen(path)
    spawn_link(fn -> serve(l, fn _ -> [] end) end)
    {:ok, s} = Client.connect(path, 1000)
    assert {:error, :closed} = Client.call(s, "ping", %{})
  end
end
