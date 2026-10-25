defmodule HerdrServer.Api.ListenerTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Listener, SocketPath, Spec}
  alias HerdrServer.Test.ApiClient

  # stands in for HerdrReload.Server: replies to every {:rollback, n} like it
  defp fake_server(ids) do
    spawn_link(fn -> serve(ids) end)
  end

  defp serve(ids) do
    receive do
      {:"$gen_call", from, {:rollback, n}} -> GenServer.reply(from, {:ok, Enum.take(ids, n)})
    end

    serve(ids)
  end

  defp path do
    dir = Path.join(System.tmp_dir!(), "hla#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, "a.sock")
  end

  defp reload_enabled(on) do
    old = Application.get_env(:herdr_reload, HerdrReload, [])
    Application.put_env(:herdr_reload, HerdrReload, Keyword.put(old, :enabled, on))
    on_exit(fn -> Application.put_env(:herdr_reload, HerdrReload, old) end)
  end

  # ApiClient.once/3, and an error must be one the method declares (or internal)
  defp once(path, method, params \\ nil) do
    reply = ApiClient.once(path, method, params)

    with %{"error" => %{"code" => code}} <- reply do
      {:ok, m} = Spec.fetch(method)
      assert String.to_existing_atom(code) in (m.errors ++ [:internal]), "#{method}: #{code}"
    end

    reply
  end

  defp result(%{"result" => r}, method) do
    assert Spec.validate_result(method, r) == :ok
    r
  end

  test "reload.rollback calls the reload server and replies with the batch ids" do
    reload_enabled(true)
    p = path()
    start_supervised!({Listener, path: p, reload_server: fake_server([3, 2])})
    r = once(p, "reload.rollback", %{"n" => 2})
    assert %{"id" => "t", "result" => %{"type" => "reload_rollback", "batches" => [3, 2]}} = r
    result(r, "reload.rollback")
    stop_supervised!(Listener)
    refute File.exists?(p)

    start_supervised!({Listener, path: p, reload_server: fake_server([])})
    # n defaults to 1; nothing rolled back is an empty list
    r = once(p, "reload.rollback")
    assert result(r, "reload.rollback")["batches"] == []
  end

  test "reload.test_on_save flips the gate mode" do
    reload_enabled(true)
    old = HerdrReload.TestGate.mode()
    on_exit(fn -> HerdrReload.TestGate.set_mode(old) end)
    p = path()
    start_supervised!({Listener, path: p, reload_server: :no_such_server})
    r = once(p, "reload.test_on_save", %{"mode" => "on"})
    assert result(r, "reload.test_on_save")["mode"] == "gate"
    assert HerdrReload.TestGate.mode() == :gate
    assert once(p, "reload.test_on_save")["result"]["mode"] == "gate"
    assert once(p, "reload.test_on_save", %{"mode" => "off"})["result"]["mode"] == "off"
    assert HerdrReload.TestGate.mode() == :off

    assert once(p, "reload.test_on_save", %{"mode" => "maybe"})["error"]["code"] ==
             "invalid_params"
  end

  test "a missing reload server is an error reply, not a crash" do
    reload_enabled(true)
    p = path()
    start_supervised!({Listener, path: p, reload_server: :no_such_server})
    assert %{"error" => %{"code" => "failed"}} = once(p, "reload.rollback", %{"n" => 1})

    assert %{"error" => %{"code" => "invalid_params"}} =
             once(p, "reload.rollback", %{"n" => 0})

    assert once(p, "ping")["result"]["type"] == "pong"
  end

  test "a hung reload server times out with an error reply" do
    reload_enabled(true)
    p = path()
    hung = spawn_link(fn -> Process.sleep(:infinity) end)
    start_supervised!({Listener, path: p, reload_server: hung, rollback_timeout_ms: 50})

    assert %{"error" => %{"code" => "timeout"}} =
             once(p, "reload.rollback", %{"n" => 1})
  end

  test "a reload server exiting mid-call is a failed reply, and the rollback runs once" do
    reload_enabled(true)
    p = path()
    me = self()

    dying =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:rollback, _}} ->
            send(me, :rollback_called)
            exit(:boom)
        end
      end)

    start_supervised!({Listener, path: p, reload_server: dying})

    assert %{"error" => %{"code" => "failed", "message" => "rollback failed: " <> _}} =
             once(p, "reload.rollback", %{"n" => 1})

    assert_received :rollback_called
    refute_received :rollback_called
  end

  test "a reload of Listener and Conn moves the acceptor and an idle conn off old code" do
    p = path()
    pid = start_supervised!({Listener, path: p})
    s = ApiClient.connect(p)
    assert ApiClient.call(s, "ping")["result"]["type"] == "pong"
    %{acceptor: acceptor, conns: conns} = :sys.get_state(pid)
    [conn] = MapSet.to_list(conns)

    for mod <- [Listener, HerdrServer.Api.Conn] do
      {^mod, bin, file} = :code.get_object_code(mod)
      {:module, ^mod} = :code.load_binary(mod, file, bin)
    end

    wait_until(fn ->
      not :erlang.check_process_code(acceptor, Listener) and
        not :erlang.check_process_code(conn, HerdrServer.Api.Conn)
    end)

    assert :code.soft_purge(Listener)
    assert :code.soft_purge(HerdrServer.Api.Conn)
    # both still serve
    assert ApiClient.call(s, "ping")["result"]["type"] == "pong"
    assert once(p, "ping")["result"]["type"] == "pong"
  end

  test "a stale socket is replaced; a live one, a regular file or a dir is left alone" do
    p = path()
    # a listener closed without unlinking leaves a stale socket file behind
    {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, p}])
    :gen_tcp.close(l)
    assert File.exists?(p)
    start_supervised!({Listener, path: p})
    assert once(p, "ping")["result"]["type"] == "pong"
    assert :ignore = Listener.init(path: p)
    long = Path.join(Path.dirname(p), String.duplicate("x", 120))
    assert :ignore = Listener.init(path: long)
    assert {:error, "path too long"} = SocketPath.prepare(long)

    file = Path.join(Path.dirname(p), "f.sock")
    File.write!(file, "keep")
    assert :ignore = Listener.init(path: file)
    assert File.read!(file) == "keep"
    dir = Path.join(Path.dirname(p), "d.sock")
    File.mkdir!(dir)
    assert :ignore = Listener.init(path: dir)
    assert File.dir?(dir)
  end

  test "a custom path's dir is neither created nor chmodded; an unwritable one is ignored" do
    p = path()
    dir = Path.dirname(p)
    File.chmod!(dir, 0o755)

    log = ExUnit.CaptureLog.capture_log(fn -> start_supervised!({Listener, path: p}) end)

    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o755
    assert log =~ "group/other"
    stop_supervised!(Listener)

    assert :ignore = Listener.init(path: Path.join(dir, "missing/a.sock"))
    refute File.exists?(Path.join(dir, "missing"))

    ro = Path.join(dir, "ro")
    File.mkdir!(ro)
    File.chmod!(ro, 0o500)
    on_exit(fn -> File.chmod(ro, 0o700) end)

    # root (e.g. the Linux container check) ignores mode bits: nothing is unwritable then
    if File.write(Path.join(ro, "probe"), "") != :ok do
      assert :ignore = Listener.init(path: Path.join(ro, "a.sock"))
    end
  end

  test "the default state dir is created 0700, an existing open one is locked to 0700" do
    base = Path.join(System.tmp_dir!(), "hls#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    old = Map.take(System.get_env(), ["HERDR_LIVE_API", "XDG_STATE_HOME"])
    System.delete_env("HERDR_LIVE_API")
    System.put_env("XDG_STATE_HOME", base)

    on_exit(fn ->
      System.delete_env("XDG_STATE_HOME")
      System.put_env(old)
    end)

    start_supervised!(Listener)
    dir = Path.join(base, "herdr-live")
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    assert once(Path.join(dir, "api.sock"), "ping")["result"]["type"] == "pong"
    stop_supervised!(Listener)

    # an old launcher made it 0755; macOS ignores the socket's own 0600
    File.chmod!(dir, 0o755)
    start_supervised!(Listener)
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
  end

  test "a default dir owned by another user is refused" do
    st = %File.Stat{type: :directory, uid: 4242, mode: 0o40700}
    assert SocketPath.lock("/d", st, 501) == {:error, "/d is owned by another user"}
    assert SocketPath.lock("/d", %{st | uid: 501}, 501) == :ok
    assert SocketPath.lock("/d", %{st | uid: 501}, nil) == {:error, "/d is owned by another user"}
  end

  test "the default path honours HERDR_LIVE_API; empty counts as unset" do
    old = System.get_env("HERDR_LIVE_API")

    on_exit(fn ->
      if old, do: System.put_env("HERDR_LIVE_API", old), else: System.delete_env("HERDR_LIVE_API")
    end)

    System.put_env("HERDR_LIVE_API", "/x/y.sock")
    assert SocketPath.path() == "/x/y.sock"
    System.put_env("HERDR_LIVE_API", "")
    assert SocketPath.path() |> String.ends_with?("/herdr-live/api.sock")
  end

  test "terminating and restarting the child removes and recreates the socket" do
    p = path()
    children = [{Listener, path: p}]

    sup =
      start_supervised!(%{
        id: :sup,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
      })

    s = ApiClient.connect(p)
    assert ApiClient.call(s, "ping")["result"]["type"] == "pong"
    assert :ok = Supervisor.terminate_child(sup, Listener)
    refute File.exists?(p)
    # open connections close with the listener
    assert {:error, :closed} = ApiClient.recv_line(s, 5000)
    assert {:ok, _} = Supervisor.restart_child(sup, Listener)
    assert once(p, "ping")["result"]["type"] == "pong"
  end

  test "conns counts open connections; a closed one is forgotten" do
    p = path()
    start_supervised!({Listener, path: p})
    a = ApiClient.connect(p)
    b = ApiClient.connect(p)
    assert ApiClient.call(a, "ping")["result"]["type"] == "pong"
    assert ApiClient.call(b, "ping")["result"]["type"] == "pong"
    assert Listener.conns() == 2
    assert result(ApiClient.call(a, "server.status"), "server.status")["api_conns"] == 2
    :gen_tcp.close(b)
    wait_until(fn -> Listener.conns() == 1 end)
  end

  test "conns/0 is 0 when the listener is gone or stops mid-call" do
    assert Listener.conns() == 0

    # a listener exiting as the call arrives (a handoff stopping it)
    dying =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, :conns} -> exit(:normal)
        end
      end)

    Process.register(dying, Listener)
    assert Listener.conns() == 0
  end

  test "an accept error other than timeout or closed is logged once and the acceptor goes on" do
    p = path()
    # accept on a connected (not listening) socket fails with einval, every time
    {:ok, l} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, p}, active: false])
    {:ok, c} = :gen_tcp.connect({:local, p}, 0, [:binary, active: false])
    {:ok, a} = :gen_tcp.accept(l, 1000)
    assert {:error, reason} = :gen_tcp.accept(a, 0)
    refute reason in [:timeout, :closed]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        acceptor = spawn(Listener, :accept, [a, self()])
        Process.sleep(500)
        assert Process.alive?(acceptor)
        Process.exit(acceptor, :kill)
      end)

    assert length(String.split(log, "api accept failed")) == 2
    Enum.each([c, a, l], &:gen_tcp.close/1)
  end

  test "api_connect is logged once a minute with the connects since the last line" do
    p = path()
    pid = start_supervised!({Listener, path: p})

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        for _ <- 1..3, do: :gen_tcp.close(ApiClient.connect(p))
        wait_until(fn -> :sys.get_state(pid).connects == 2 end)
      end)

    assert length(String.split(log, "api_connect")) == 2
    assert log =~ "count=1"

    :sys.replace_state(pid, fn st -> %{st | connect_logged_at: st.connect_logged_at - 61_000} end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        :gen_tcp.close(ApiClient.connect(p))
        wait_until(fn -> :sys.get_state(pid).connects == 0 end)
      end)

    assert log =~ "count=3"
  end

  defp wait_until(f, n \\ 200) do
    cond do
      f.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(f, n - 1)
    end
  end
end
