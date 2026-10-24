defmodule HerdrIntegration.CliConformanceTest do
  @moduledoc """
  The CLI (`HerdrCli.Argv`, no server deps) and the API spec agree: every method is
  reachable from argv with params the Spec accepts, and every Spec `cli` string is
  the parser's own usage line for that method.
  """
  use ExUnit.Case, async: true

  alias HerdrCli.Argv
  alias HerdrServer.Api.Spec

  @env %{"HERDR_PANE_ID" => "p4"}

  # argv lines covering every method (api.schema is reached through `api schema`,
  # but `api call` is the generic escape hatch and is checked separately)
  @fixtures [
    "ping",
    "server status",
    "server status --kv",
    "rollback",
    "rollback 2",
    "test-on-save",
    "test-on-save on",
    "workspace list",
    "workspace get w1",
    "workspace create --label api --focus",
    "workspace focus w1",
    "workspace rename w1 api",
    "workspace close w1",
    "tab list --workspace w1",
    "tab get w1:t1",
    "tab create --workspace w1 --label t --focus",
    "tab focus w1:t1",
    "tab rename w1:t1 t",
    "tab close w1:t1",
    "pane list --workspace w1 --tab w1:t1",
    "pane get p1",
    "pane current",
    "pane split --direction right --ratio 0.4 --focus",
    "pane split p1 --direction down",
    "pane close p1",
    "pane focus p1",
    "pane layout",
    "pane process-info",
    "pane send-text p1 hi",
    "pane send-keys p1 C-c Enter",
    "pane run p1 ls",
    "pane read --source recent --lines 20",
    "pane wait-output --match done --timeout 1000",
    "pane wait-output p1 --regex x --source visible --lines 5",
    "agent list",
    "agent get p1",
    "agent read p1 --source recent --lines 5",
    "agent explain p1",
    "agent wait p1 --until idle --until done --timeout 100",
    "agent prompt p1 hello",
    "agent send-keys p1 Enter",
    "events subscribe pane.created layout.updated --pane p1 --tab w1:t1 --workspace w1"
  ]

  defp parsed do
    for line <- @fixtures do
      case Argv.parse(OptionParser.split(line), @env) do
        {:call, method, params, _out} -> {line, method, params}
        {:subscribe, params} -> {line, "events.subscribe", params}
        other -> flunk("#{line} did not parse: #{inspect(other)}")
      end
    end
  end

  test "every Spec method except api.schema is produced by a fixture" do
    produced = parsed() |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    missing = for m <- Spec.methods(), m.name != "api.schema", m.name not in produced, do: m.name
    assert missing == []
  end

  test "every fixture's params pass Spec.validate_params/2" do
    for {line, method, params} <- parsed() do
      assert {:ok, _} = Spec.validate_params(method, params), "#{line}: #{inspect(params)}"
    end
  end

  test "every Spec cli string starts with a verb the parser accepts" do
    for m <- Spec.methods() do
      assert "herdr-live " <> rest = m.cli
      [verb | _] = String.split(rest, " ")
      assert verb in Argv.verbs(), "#{m.name}: #{m.cli}"
    end
  end

  test "every Spec cli string is the parser's usage line for that method" do
    usages = Map.new(Argv.commands(), &{&1.method, "herdr-live " <> &1.usage})

    for m <- Spec.methods() do
      assert usages[m.name] == m.cli, "#{m.name}: spec #{inspect(m.cli)}"
    end
  end

  test "the parser's event types are the Spec's" do
    assert Argv.event_types() == Spec.event_types()
  end
end
