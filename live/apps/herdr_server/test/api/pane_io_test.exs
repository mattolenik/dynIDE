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
    {e["code"], e}
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
    path: path,
    pty: pty,
    vt: vt
  } do
    Fake.Vt.set_mode(vt, :bracketed_paste, true)
    ok!(s, "pane.run", Map.put(@p, "command", "cmd"))
    assert writes(pty) == "\e[200~cmd\e[201~\r"
  end

  test "run without bracketed paste", %{s: s, pty: pty} do
    ok!(s, "pane.run", Map.put(@p, "command", "cmd"))
    assert writes(pty) == "cmd\r"
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

  test "agent methods are not available until M11", %{s: s} do
    for m <- Spec.methods(), m.group == "agent" do
      params =
        for p <- m.params, p.required, into: %{} do
          {p.name, if(p.type == {:list, :string}, do: ["a"], else: "x")}
        end

      assert {"not_available", e} = err(s, m.name, params)
      assert e["data"]["requires"] == "M11 detection"
    end
  end
end
