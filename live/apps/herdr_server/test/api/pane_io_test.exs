defmodule HerdrServer.Api.PaneIoTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Test.ApiClient

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    dir = Path.join(System.tmp_dir!(), "hlp#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "a.sock")
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    s = ApiClient.connect(path)
    ApiClient.call(s, "workspace.list")
    {:ok, %{pty: pty, vt: vt}} = Fake.Keeper.lookup(Rows.kernel_id(1))
    %{s: s, path: path, pty: pty, vt: vt}
  end

  defp ok!(s, method, params) do
    reply = ApiClient.call(s, method, params)
    assert %{"result" => r} = reply, "#{method}: #{inspect(reply)}"
    assert Spec.validate_result(method, r) == :ok
    r
  end

  defp err(s, method, params) do
    assert %{"error" => e} = ApiClient.call(s, method, params)
    {:ok, m} = Spec.fetch(method)

    assert String.to_existing_atom(e["code"]) in (m.errors ++ [:internal]),
           "#{method}: #{inspect(e)}"

    {e["code"], e}
  end

  defp conn_of(path, fun) do
    before = :sys.get_state(Listener).conns
    c = ApiClient.connect(path)
    ApiClient.call(c, "ping")
    [conn] = MapSet.to_list(MapSet.difference(:sys.get_state(Listener).conns, before))
    fun.(c, conn)
  end

  defp wait_req(id, match),
    do:
      JSON.encode!(%{
        "id" => id,
        "method" => "pane.wait_for_output",
        "params" => %{"pane_id" => "p1", "match" => match}
      })

  defp wait_until(f, n) do
    cond do
      f.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(f, n - 1)
    end
  end

  defp writes(pty), do: pty |> Fake.Pty.writes() |> IO.iodata_to_binary()
  @p %{"pane_id" => "p1"}

  test "send_text writes raw bytes", %{s: s, pty: pty} do
    ok!(s, "pane.send_text", Map.put(@p, "text", "ls -l\n"))
    assert writes(pty) == "ls -l\n"
  end

  test "send_text writes every 64 KiB chunk", %{s: s, pty: pty} do
    text = String.duplicate("x", 150_000)
    ok!(s, "pane.send_text", Map.put(@p, "text", text))
    assert writes(pty) == text
  end

  test "send_text after backpressure says how much was written", %{s: s, pty: pty} do
    text = String.duplicate("a", 65_536) <> String.duplicate("b", 10)
    Fake.Pty.backpressure_once_after(pty, 1)
    {code, e} = err(s, "pane.send_text", Map.put(@p, "text", text))
    assert code == "backpressure"
    assert e["data"] == %{"written" => 65_536}
    # resending from `written` gives the pane the text exactly once
    rest = binary_part(text, 65_536, 10)
    ok!(s, "pane.send_text", Map.put(@p, "text", rest))
    assert writes(pty) == text
  end

  test "a write the kernel refuses otherwise is failed", %{s: s, pty: pty} do
    Fake.Pty.fail_once_after(pty, 0, :too_large)
    assert {"failed", e} = err(s, "pane.send_text", Map.put(@p, "text", "x"))
    assert e["data"] == %{"written" => 0}
    Fake.Pty.fail_once_after(pty, 0, :too_large)
    assert {"failed", _} = err(s, "pane.send_keys", Map.put(@p, "keys", ["a"]))
  end

  test "run queues through backpressure and answers ok", %{s: s, pty: pty} do
    Fake.Pty.set_backpressure(pty, true)
    ok!(s, "pane.run", Map.put(@p, "command", "cmd"))
    Fake.Pty.set_backpressure(pty, false)
    wait_until(fn -> writes(pty) == "cmd\r" end, 80)
  end

  test "send_text behind a queued run keeps its order", %{s: s, pty: pty} do
    Fake.Pty.set_backpressure(pty, true)
    ok!(s, "pane.run", Map.put(@p, "command", "cmd"))
    # the run is still queued: the text queues behind it instead of overtaking it
    ok!(s, "pane.send_text", Map.put(@p, "text", "X"))
    Fake.Pty.set_backpressure(pty, false)
    wait_until(fn -> writes(pty) == "cmd\rX" end, 80)
  end

  test "send_keys page up reaches the child at a shell prompt", %{s: s, pty: pty, vt: vt} do
    :ok = Fake.Vt.set_history(vt, for(i <- 1..60, do: "h#{i}"))
    %{offset: bottom} = Fake.Vt.scrollbar(vt)
    ok!(s, "pane.send_keys", Map.put(@p, "keys", ["pageup"]))
    assert writes(pty) == "\e[5~"
    assert Fake.Vt.scrollbar(vt).offset == bottom
  end

  test "send_keys writes nothing when any key is bad", %{s: s, pty: pty} do
    {code, e} = err(s, "pane.send_keys", Map.put(@p, "keys", ["a", "bogus"]))
    assert code == "invalid_params"
    assert e["message"] =~ "bogus"
    assert writes(pty) == ""
    ok!(s, "pane.send_keys", Map.put(@p, "keys", ["a", "enter"]))
    assert writes(pty) == "a\r"
  end

  test "send_keys reports backpressure", %{s: s, pty: pty} do
    Fake.Pty.set_backpressure(pty, true)
    assert {"backpressure", _} = err(s, "pane.send_keys", Map.put(@p, "keys", ["a"]))
  end

  test "run brackets the command when the pane enabled bracketed paste", %{
    s: s,
    pty: pty,
    vt: vt
  } do
    Fake.Vt.set_mode(vt, :bracketed_paste, true)
    ok!(s, "pane.run", Map.put(@p, "command", "cmd"))
    # the paste queue writes after the reply
    wait_until(fn -> writes(pty) == "\e[200~cmd\e[201~\r" end, 80)
  end

  test "run without bracketed paste", %{s: s, pty: pty} do
    ok!(s, "pane.run", Map.put(@p, "command", "cmd"))
    wait_until(fn -> writes(pty) == "cmd\r" end, 80)
  end

  test "read visible and lines", %{s: s, pty: pty} do
    Fake.Pty.output(pty, "one\r\ntwo\r\nthree")
    wait_text(s, "three")
    r = ok!(s, "pane.read", @p)
    assert r["text"] == "one\ntwo\nthree"
    assert r["source"] == "visible"
    assert ok!(s, "pane.read", Map.put(@p, "lines", 1))["text"] == "three"

    rec = ok!(s, "pane.read", Map.put(@p, "source", "recent"))
    assert rec["text"] == "one\ntwo\nthree"

    assert ok!(s, "pane.read", Map.merge(@p, %{"source" => "recent", "lines" => 2}))["text"] ==
             "two
three"

    assert ok!(s, "pane.read", Map.merge(@p, %{"source" => "recent", "lines" => 100}))["text"] =~
             "one"
  end

  defp wait_text(s, text, n \\ 100) do
    if ApiClient.call(s, "pane.read", @p)["result"]["text"] =~ text or n == 0,
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_text(s, text, n - 1)
        )
  end

  test "wait_for_output matches now, later, regex", %{s: s, pty: pty} do
    Fake.Pty.output(pty, "hello world\r\n")
    wait_text(s, "hello")
    r = ok!(s, "pane.wait_for_output", Map.put(@p, "match", "world"))
    assert r["line"] == "hello world"
    assert r["pane_id"] == "p1"

    spawn(fn ->
      Process.sleep(200)
      Fake.Pty.output(pty, "ready 42\r\n")
    end)

    r = ok!(s, "pane.wait_for_output", Map.put(@p, "regex", "ready \\d+"))
    assert r["line"] == "ready 42"
  end

  test "wait_for_output times out and validates", %{s: s} do
    assert {"timeout", _} =
             err(
               s,
               "pane.wait_for_output",
               Map.merge(@p, %{"match" => "zzz", "timeout_ms" => 250})
             )

    assert {"invalid_params", _} = err(s, "pane.wait_for_output", @p)

    assert {"invalid_params", _} =
             err(s, "pane.wait_for_output", Map.merge(@p, %{"match" => "a", "regex" => "b"}))

    assert {"invalid_params", _} = err(s, "pane.wait_for_output", Map.put(@p, "regex", "("))
  end

  test "wait_for_output answers not_found when the pane closes", %{s: s, path: path} do
    ok!(s, "pane.split", Map.put(@p, "direction", "right"))
    p2 = %{"pane_id" => "p2"}

    task =
      Task.async(fn ->
        ApiClient.call(
          ApiClient.connect(path),
          "pane.wait_for_output",
          Map.put(p2, "match", "zzz")
        )
      end)

    Process.sleep(300)
    ok!(s, "pane.close", p2)
    assert %{"error" => %{"code" => "not_found"}} = Task.await(task, 10_000)
  end

  test "a running wait moves off old PaneIo and Conn code and still answers", %{
    path: path,
    pty: pty
  } do
    conn_of(path, fn c, conn ->
      :ok = ApiClient.send_line(c, wait_req("w", "reloaded"))
      Process.sleep(300)

      for mod <- [HerdrServer.Api.Handlers.PaneIo, HerdrServer.Api.Conn] do
        {^mod, bin, file} = :code.get_object_code(mod)
        {:module, ^mod} = :code.load_binary(mod, file, bin)
      end

      # every conn (this wait, the idle setup one) leaves the old code within ~2 s
      wait_until(
        fn ->
          :code.soft_purge(HerdrServer.Api.Handlers.PaneIo) and
            :code.soft_purge(HerdrServer.Api.Conn)
        end,
        120
      )

      refute :erlang.check_process_code(conn, HerdrServer.Api.Conn)
      Fake.Pty.output(pty, "reloaded\r\n")

      assert %{"id" => "w", "result" => %{"type" => "output_matched", "line" => "reloaded"}} =
               ApiClient.recv_line(c)
    end)
  end

  test "a line pipelined behind a wait is answered after it", %{path: path, pty: pty} do
    conn_of(path, fn c, _conn ->
      :ok = ApiClient.send_line(c, [wait_req("w", "go"), "\n", ~s({"id":"p","method":"ping"})])
      Process.sleep(300)
      Fake.Pty.output(pty, "go\r\n")
      assert %{"id" => "w", "result" => %{"line" => "go"}} = ApiClient.recv_line(c)
      assert %{"id" => "p", "result" => %{"type" => "pong"}} = ApiClient.recv_line(c)
    end)
  end

  test "a close behind a pipelined line still stops an untimed wait", %{path: path} do
    conn_of(path, fn c, conn ->
      ref = Process.monitor(conn)
      :ok = ApiClient.send_line(c, [wait_req("w", "never"), "\n", ~s({"id":"p","method":"ping"})])
      Process.sleep(300)
      :gen_tcp.close(c)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 5000
    end)
  end

  test "an untimed wait stops when its client disconnects", %{path: path} do
    before = :sys.get_state(Listener).conns
    c = ApiClient.connect(path)
    ApiClient.call(c, "ping")
    [conn] = MapSet.to_list(MapSet.difference(:sys.get_state(Listener).conns, before))
    ref = Process.monitor(conn)

    req = %{
      "id" => "w",
      "method" => "pane.wait_for_output",
      "params" => Map.put(@p, "match", "never")
    }

    :ok = ApiClient.send_line(c, JSON.encode!(req))
    Process.sleep(300)
    :gen_tcp.close(c)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 2000
  end

  test "unknown pane is not_found", %{s: s} do
    for {m, extra} <- [
          {"pane.send_text", %{"text" => "x"}},
          {"pane.send_keys", %{"keys" => ["a"]}},
          {"pane.run", %{"command" => "x"}},
          {"pane.read", %{}},
          {"pane.wait_for_output", %{"match" => "x"}}
        ] do
      assert {"not_found", _} = err(s, m, Map.put(extra, "pane_id", "p99"))
    end
  end
end
