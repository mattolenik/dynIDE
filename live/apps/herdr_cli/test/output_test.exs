defmodule HerdrCli.OutputTest do
  use ExUnit.Case, async: true

  alias HerdrCli.Output

  defp ok(result), do: %{"id" => "cli:x", "result" => result}

  # herdr's print_response (src/cli.rs): the whole reply, one line
  test "json prints the whole reply {id, result} as one line with sorted keys" do
    reply = ok(%{"type" => "pong", "version" => "0.1.0", "gen" => 2})

    assert Output.render(:json, reply) ==
             {0, ~s({"id":"cli:x","result":{"gen":2,"type":"pong","version":"0.1.0"}}\n)}

    nested = ok(%{"type" => "x", "b" => [%{"z" => 1, "a" => nil}], "a" => "é"})

    assert Output.render(:json, nested) ==
             {0, ~s({"id":"cli:x","result":{"a":"é","b":[{"a":null,"z":1}],"type":"x"}}\n)}
  end

  test "a herdr plugin's .result.pane.pane_id reads the split pane's id" do
    {0, line} = Output.render(:json, ok(%{"type" => "pane_info", "pane" => %{"pane_id" => "p2"}}))
    assert %{"result" => %{"pane" => %{"pane_id" => "p2"}}} = JSON.decode!(line)
  end

  test "quiet prints nothing on success (herdr's Output::Quiet)" do
    assert Output.render(:quiet, ok(%{"type" => "ok"})) == {0, ""}
  end

  test "explain_json prints the bare explain object (herdr's agent explain --json)" do
    reply =
      ok(%{"type" => "agent_explain", "agent" => %{"state" => "idle"}, "explanation" => "x"})

    assert Output.render(:explain_json, reply) == {0, ~s({"state":"idle"}\n)}
  end

  test "explain prints the explanation text as is" do
    reply = ok(%{"type" => "agent_explain", "agent" => %{}, "explanation" => "agent: x\n"})
    assert Output.render(:explain, reply) == {0, "agent: x\n"}
  end

  test "path prints the path plus a newline" do
    assert Output.render(:path, ok(%{"type" => "plugin_dir", "path" => "/c/p"})) == {0, "/c/p\n"}
  end

  test "text prints the text plus a newline" do
    assert Output.render(:text, ok(%{"type" => "pane_read", "text" => "a\nb"})) == {0, "a\nb\n"}
  end

  test "rollback prints ok <ids> or ok none" do
    assert Output.render(:rollback, ok(%{"type" => "reload_rollback", "batches" => []})) ==
             {0, "ok none\n"}

    assert Output.render(:rollback, ok(%{"type" => "reload_rollback", "batches" => [3, 2]})) ==
             {0, "ok 3 2\n"}
  end

  test "gate prints ok <mode>" do
    assert Output.render(:gate, ok(%{"type" => "test_on_save", "mode" => "gate"})) ==
             {0, "ok gate\n"}
  end

  test "lines prints key=value per field, sorted, without type" do
    reply =
      ok(%{"type" => "server_status", "gen" => 2, "handoff" => nil, "test_on_save" => "off"})

    assert Output.render(:lines, reply) == {0, "gen=2\nhandoff=\ntest_on_save=off\n"}
  end

  test "an error reply goes to stderr as the whole reply {error, id}, exit 1" do
    reply = %{"id" => "cli:x", "error" => %{"code" => "not_found", "message" => "no pane p9"}}
    line = ~s({"error":{"code":"not_found","message":"no pane p9"},"id":"cli:x"}\n)
    assert Output.render(:json, reply) == {1, {:stderr, line}}
    assert Output.render(:quiet, reply) == {1, {:stderr, line}}
    assert {1, {:stderr, _}} = Output.render(:rollback, reply)
  end

  test "a reply of an unexpected shape is an error, not a crash" do
    assert {1, {:stderr, _}} = Output.render(:text, ok(%{"type" => "pane_read"}))
    assert {1, {:stderr, _}} = Output.render(:json, %{"id" => "cli"})
  end

  test "events print one json line each" do
    assert Output.event(%{"event" => "pane.created", "data" => %{"pane_id" => "p2"}}) ==
             ~s({"data":{"pane_id":"p2"},"event":"pane.created"}\n)
  end
end
