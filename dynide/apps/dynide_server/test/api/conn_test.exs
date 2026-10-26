defmodule DynideServer.Api.ConnTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias DynideServer.Api.{Listener, Spec}
  alias DynideServer.Test.ApiClient

  defmodule Boom do
    @moduledoc false
    alias DynideServer.Api.Router
    def handle("ping", _params, _ctx), do: raise("boom")
    def handle(method, params, ctx), do: Router.handle(method, params, ctx)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "hlc#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "a.sock")}
  end

  defp start(path, opts \\ []) do
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server] ++ opts})
    ApiClient.connect(path)
  end

  defp ok!(reply, method) do
    assert %{"result" => r} = reply
    assert Spec.validate_result(method, r) == :ok
    r
  end

  defp code(%{"error" => %{"code" => c}}), do: c

  # an error of a known method must be one it declares (or the implicit internal)
  defp code(method, reply) do
    c = code(reply)
    {:ok, m} = Spec.fetch(method)
    assert String.to_existing_atom(c) in (m.errors ++ [:internal]), "#{method}: #{c}"
    c
  end

  test "ping echoes the id and answers pong", %{path: p} do
    s = start(p)
    reply = ApiClient.call(s, "ping", nil, "abc")
    assert reply["id"] == "abc"
    assert ok!(reply, "ping")["type"] == "pong"
  end

  test "parse errors, bad requests, unknown methods and bad params", %{path: p} do
    s = start(p)
    :ok = ApiClient.send_line(s, "not json")
    assert %{"id" => "", "error" => %{"code" => "parse_error"}} = ApiClient.recv_line(s)
    :ok = ApiClient.send_line(s, ~s({"id":"a"}))
    assert %{"id" => "a", "error" => %{"code" => "invalid_request"}} = ApiClient.recv_line(s)
    :ok = ApiClient.send_line(s, ~s({"id":7,"method":"ping"}))
    assert %{"id" => "", "error" => %{"code" => "invalid_request"}} = ApiClient.recv_line(s)
    :ok = ApiClient.send_line(s, ~s({"id":"b","method":"ping","params":[]}))
    assert %{"id" => "b", "error" => %{"code" => "invalid_request"}} = ApiClient.recv_line(s)
    :ok = ApiClient.send_line(s, ~s([1]))
    assert %{"id" => "", "error" => %{"code" => "invalid_request"}} = ApiClient.recv_line(s)
    assert code(ApiClient.call(s, "no.such")) == "unknown_method"
    assert code("ping", ApiClient.call(s, "ping", %{"x" => 1})) == "invalid_params"

    assert code("reload.rollback", ApiClient.call(s, "reload.rollback", %{"n" => "two"})) ==
             "invalid_params"

    # the connection is still usable
    assert ok!(ApiClient.call(s, "ping"), "ping")["type"] == "pong"
  end

  test "two requests on one connection are answered in order", %{path: p} do
    s = start(p)

    :ok =
      ApiClient.send_line(s, [
        ~s({"id":"1","method":"ping"}\n),
        ~s({"id":"2","method":"api.schema"})
      ])

    assert %{"id" => "1", "result" => %{"type" => "pong"}} = ApiClient.recv_line(s)
    assert %{"id" => "2"} = two = ApiClient.recv_line(s)
    schema = ok!(two, "api.schema")
    assert length(schema["methods"]) == length(Spec.methods())
    assert Enum.any?(schema["methods"], &(&1["name"] == "reload.rollback"))
  end

  test "a line over 1 MiB is refused and the connection closed", %{path: p} do
    s = start(p)
    :ok = ApiClient.send_line(s, String.duplicate("a", 2 * 1024 * 1024))
    assert %{"id" => "", "error" => %{"code" => "invalid_request"}} = ApiClient.recv_line(s)
    assert {:error, :closed} = ApiClient.recv_line(s)
  end

  test "a handler that raises answers internal", %{path: p} do
    s = start(p, router: Boom)

    assert %{"id" => "t", "error" => %{"code" => "internal", "message" => msg}} =
             ApiClient.call(s, "ping")

    assert msg =~ "boom"
    assert ok!(ApiClient.call(s, "server.status"), "server.status")["type"] == "server_status"
  end

  test "reload verbs answer not_available when reload is disabled", %{path: p} do
    refute Application.get_env(:dynide_reload, DynideReload, [])[:enabled]
    s = start(p)

    assert code("reload.rollback", ApiClient.call(s, "reload.rollback", %{"n" => 1})) ==
             "not_available"

    assert code("reload.test_on_save", ApiClient.call(s, "reload.test_on_save")) ==
             "not_available"

    status = ok!(ApiClient.call(s, "server.status"), "server.status")
    assert status["reload_enabled"] == false
    assert status["test_on_save"] == nil
  end

  test "server.status reports gen, os pid and counts", %{path: p} do
    s = start(p)
    status = ok!(ApiClient.call(s, "server.status"), "server.status")
    assert status["os_pid"] == String.to_integer(System.pid())
    assert status["gen"] == 0
    assert status["api_conns"] == 1
    assert is_integer(status["workspaces"]) and is_integer(status["panes"])
  end

  test "telemetry: connect, denied and error lines", %{path: p} do
    log =
      capture_log(fn ->
        s = start(p, router: Boom)
        assert code(ApiClient.call(s, "no.such")) == "unknown_method"
        assert code(ApiClient.call(s, String.duplicate("x", 300))) == "unknown_method"
        assert code("ping", ApiClient.call(s, "ping")) == "internal"
      end)

    assert log =~ ~r/dynide-event api_connect ts=\d+ conns=1/
    assert log =~ ~r/dynide-event api_denied ts=\d+ method=no.such code=unknown_method/
    assert log =~ ~r/method=x{100} code=unknown_method/
    refute log =~ String.duplicate("x", 101)
    assert log =~ ~r/dynide-event api_error ts=\d+ method=ping code=internal msg=/
  end
end
