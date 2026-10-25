defmodule HerdrServer.WorkspaceFactsTest do
  use ExUnit.Case, async: false

  alias HerdrServer.App.Actions
  alias HerdrServer.WorkspaceFacts

  # injected readers: app and cwds from the test's Agent, events back to the test
  defmodule Reader do
    @moduledoc false
    def app, do: Agent.get(agent(), & &1.app)
    def cwd(id), do: Agent.get(agent(), &Map.get(&1.cwds, id))
    def notify(event), do: send(Agent.get(agent(), & &1.test), {:notify, event})
    defp agent, do: :persistent_term.get(__MODULE__)
  end

  test "sends one event per root-pane cwd change" do
    {app, _} = Actions.new_workspace(elem(Actions.init(%{cols: 80, rows: 24}), 0))
    {app, _} = Actions.split(app, :horizontal)
    test = self()
    cwds = %{1 => "/a", 3 => "/split"}
    agent = start_supervised!({Agent, fn -> %{app: app, cwds: cwds, test: test} end})
    :persistent_term.put(Reader, agent)

    start_supervised!(
      {WorkspaceFacts,
       enabled: true,
       name: nil,
       poll_ms: 10,
       app: {Reader, :app},
       cwd: {Reader, :cwd},
       notify: {Reader, :notify}}
    )

    # workspace 2's root pane (2) has no cwd yet: nothing for it
    assert_receive {:notify, {:workspace_cwd, 1, "/a"}}
    Agent.update(agent, &put_in(&1.cwds[2], "/b"))
    assert_receive {:notify, {:workspace_cwd, 2, "/b"}}
    # the split pane (3) is not a root; an unchanged cwd is not resent
    Agent.update(agent, &put_in(&1.cwds[3], "/elsewhere"))
    Agent.update(agent, &put_in(&1.cwds[1], "/a2"))
    assert_receive {:notify, {:workspace_cwd, 1, "/a2"}}
    Process.sleep(50)
    refute_received {:notify, _}
  end
end
