defmodule HerdrIntegration.CliConformanceTest do
  @moduledoc """
  The CLI (`HerdrCli.Argv`, no server deps) and the API spec agree: every method is
  reachable from argv with params the Spec accepts, and every Spec `cli` string is
  the parser's own usage line for that method.
  """
  use ExUnit.Case, async: true

  alias HerdrCli.Argv
  alias HerdrServer.Api.Spec
  alias HerdrTerm.Remote.Args

  @env %{"HERDR_PANE_ID" => "p4"}

  # argv lines covering every method (api.schema is reached through `api schema`,
  # but `api call` is the generic escape hatch and is checked separately)
  @fixtures [
    "ping",
    "server status",
    "server status --kv",
    "session list",
    "session get",
    "session get default",
    "api snapshot",
    "client list",
    "rollback",
    "rollback 2",
    "test-on-save",
    "test-on-save on",
    "workspace list",
    "workspace get w1",
    "workspace create --label api --focus",
    "workspace focus w1",
    "workspace rename w1 api",
    "workspace move w1 0",
    "workspace close w1",
    "tab list --workspace w1",
    "tab get w1:t1",
    "tab create --workspace w1 --label t --focus",
    "tab focus w1:t1",
    "tab rename w1:t1 t",
    "tab move w1:t1 2",
    "tab close w1:t1",
    "pane list --workspace w1 --tab w1:t1",
    "pane get p1",
    "pane current",
    "pane split --direction right --ratio 0.4 --focus",
    "pane split p1 --direction down",
    "pane close p1",
    "pane focus p1",
    "pane zoom",
    "pane zoom p1 --on",
    "pane zoom --off",
    "pane layout",
    "pane process-info",
    "pane send-text p1 hi",
    "pane send-keys p1 C-c Enter",
    "pane run p1 ls",
    "pane read --source recent --lines 20",
    "pane wait-output --match done --timeout 1000",
    "pane wait-output p1 --regex x --source visible --lines 5",
    "notification show hi --body there --pane p1",
    "title set hi",
    "title clear",
    "popup close",
    "agent list",
    "agent get p1",
    "agent read p1 --source recent --lines 5",
    "agent explain p1",
    "agent explain p1 --json --verbose",
    "server agent-manifests",
    "server reload-agent-manifests",
    "pane report-agent p1 --source s --agent claude --state idle --message hi --seq 1",
    "pane release-agent p1 --source s --agent claude --seq 2",
    "pane report-agent-session p1 --source herdr:claude --agent claude --agent-session-id x",
    "pane report-agent-session p1 --source s --agent a --seq 1 --agent-session-path /x " <>
      "--session-start-source resume -- a --resume x",
    "pane report-metadata --source s --token pr=#12 --clear-token old --seq 3 --ttl-ms 500",
    "workspace report-metadata w1 --source s --token build=ok",
    "agent wait p1 --until idle --until done --timeout 100",
    "agent prompt p1 hello",
    "agent send-keys p1 Enter",
    "events subscribe pane.created layout.updated --pane p1 --tab w1:t1 --workspace w1",
    "pane split p1 --direction right --no-focus",
    "pane split p1 --direction down --cwd /tmp --env A=1 --env B=2",
    "pane focus-direction --direction left",
    "pane focus-direction p1 --direction right",
    "pane swap p1 --direction down",
    "pane resize p1 --direction up --amount 0.1",
    "pane rename p1 logs",
    "pane rename p1",
    "pane link activate p1 --col 0 --row 2 --modifier ctrl",
    "plugin list --plugin a --json",
    "plugin install o/r --ref main --yes",
    "plugin link ./x --disabled",
    "plugin uninstall a",
    "plugin remove a",
    "plugin unlink o/r/sub",
    "plugin enable a",
    "plugin disable a",
    "plugin config-dir a",
    "plugin action list --plugin a",
    "plugin action invoke hello --plugin a",
    "plugin log list --plugin a --limit 10",
    "plugin pane open --plugin a --entrypoint b --placement split --width 40% --height 10 " <>
      "--workspace w1 --target-pane p1 --direction down --cwd /tmp --env A=1 --env B=2 --no-focus",
    "plugin pane focus p1",
    "plugin pane close p1",
    "worktree list --workspace w1",
    "worktree list --cwd /tmp/r",
    "worktree create --branch feat --cwd /tmp/r --base main --path /tmp/wt --label L --focus",
    "worktree open --branch feat --workspace w1 --label L --focus",
    "worktree open --path wt",
    "worktree remove w2 --force"
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
    # an alias row (`plugin remove`) is another spelling, not the Spec's cli string
    usages =
      for c <- Argv.commands(),
          not Map.get(c, :alias, false),
          into: %{},
          do: {c.method, "herdr-live " <> c.usage}

    for m <- Spec.methods() do
      assert usages[m.name] == m.cli, "#{m.name}: spec #{inspect(m.cli)}"
    end
  end

  test "the parser's event types are the Spec's" do
    assert Argv.event_types() == Spec.event_types()
  end

  test "client verbs are the remote client's usage lines, and the launcher prints them" do
    clis = Spec.client_verbs() |> Enum.map(& &1.cli)
    usage = Enum.map(Args.usage_lines(), &"herdr-live #{&1}")
    assert usage -- clis == []
    assert "herdr-live attach-relay [<session>]" in clis

    launcher = File.read!(Path.expand("../../../bin/herdr-live", __DIR__))
    for line <- usage, do: assert(launcher =~ line)
  end
end
