defmodule HerdrServer.WorkspaceFactsTest do
  use ExUnit.Case, async: false

  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Layout
  alias HerdrServer.Pane.Rows
  alias HerdrServer.WorkspaceFacts

  # injected readers: app and cwds from the test's Agent, events back to the test
  defmodule Reader do
    @moduledoc false
    def app, do: Agent.get(agent(), & &1.app)
    def cwd(id), do: Agent.get(agent(), &Map.get(&1.cwds, id))
    def notify(event), do: send(Agent.get(agent(), & &1.test), {:notify, event})
    def git(cwd), do: Agent.get(agent(), &Map.get(&1.git, cwd))
    def slow_git("/slow"), do: Process.sleep(:infinity)
    def slow_git(cwd), do: git(cwd)
    defp agent, do: :persistent_term.get(__MODULE__)
  end

  defp git_facts(app, git, runner) do
    test = self()
    agent = start_supervised!({Agent, fn -> %{app: app, cwds: %{}, git: git, test: test} end})
    :persistent_term.put(Reader, agent)

    start_supervised!(
      {WorkspaceFacts,
       enabled: true,
       name: nil,
       poll_ms: 60_000,
       git_ms: 10,
       app: {Reader, :app},
       cwd: {Reader, :cwd},
       git: {Reader, runner},
       notify: {Reader, :notify}}
    )

    agent
  end

  defp with_cwds(app, cwds) do
    Enum.reduce(cwds, app, fn {id, cwd}, app ->
      elem(Actions.apply(app, {:workspace_cwd, id, cwd, nil}), 0)
    end)
  end

  test "git: one event per workspace info change; no cwd sends nothing" do
    {app, _} = Actions.new_workspace(elem(Actions.init(%{cols: 80, rows: 24}), 0))
    {app, _} = Actions.new_workspace(app)
    # workspaces 1 and 2 share a repo; 3 has no cwd
    app = with_cwds(app, [{1, "/r"}, {2, "/r"}])
    main = %{branch: "main", ahead: 0, behind: 0}
    agent = git_facts(app, %{"/r" => main}, :git)

    assert_receive {:notify, {:workspace_git, 1, ^main}}, 1000
    assert_receive {:notify, {:workspace_git, 2, ^main}}, 1000
    Process.sleep(50)
    refute_received {:notify, _}

    ahead = %{main | ahead: 1}
    Agent.update(agent, &put_in(&1.git["/r"], ahead))
    assert_receive {:notify, {:workspace_git, 1, ^ahead}}, 1000
    assert_receive {:notify, {:workspace_git, 2, ^ahead}}, 1000
    # leaving the repo clears it once
    Agent.update(agent, &%{&1 | git: %{}})
    assert_receive {:notify, {:workspace_git, 1, nil}}, 1000
    assert_receive {:notify, {:workspace_git, 2, nil}}, 1000
    Process.sleep(50)
    refute_received {:notify, _}
  end

  test "git: a call past 2 s is nil and the poll goes on" do
    {app, _} = Actions.new_workspace(elem(Actions.init(%{cols: 80, rows: 24}), 0))
    app = with_cwds(app, [{1, "/slow"}, {2, "/fast"}])
    fast = %{branch: "f", ahead: 0, behind: 2}
    agent = git_facts(app, %{"/fast" => fast}, :slow_git)

    # the slow call blocks only this poller, never past its 2 s budget
    assert_receive {:notify, {:workspace_git, 2, ^fast}}, 3000
    refute_received {:notify, {:workspace_git, 1, _}}
    Agent.update(agent, &put_in(&1.git["/fast"], %{fast | behind: 0}))
    assert_receive {:notify, {:workspace_git, 2, %{behind: 0}}}, 3000
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
    assert_receive {:notify, {:workspace_cwd, 1, "/a", "a"}}, 1000
    Agent.update(agent, &put_in(&1.cwds[2], "/b"))
    assert_receive {:notify, {:workspace_cwd, 2, "/b", "b"}}, 1000
    # the split pane (3) is not a root; an unchanged cwd is not resent
    Agent.update(agent, &put_in(&1.cwds[3], "/elsewhere"))
    Agent.update(agent, &put_in(&1.cwds[1], "/a2"))
    assert_receive {:notify, {:workspace_cwd, 1, "/a2", "a2"}}, 1000
    Process.sleep(50)
    refute_received {:notify, _}
  end

  test "default wiring: mirror, Facts.cwd and the Store rename an auto-named workspace" do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok = Store.event({:resize, %{cols: 80, rows: 24}}, nil)
    [ws] = Store.snapshot().session.workspaces
    assert ws.auto_name
    [root | _] = Layout.pane_ids(hd(ws.tabs).layout)
    {:ok, res} = Fake.Keeper.lookup(Rows.kernel_id(root))
    # no .git above it, so the label is the basename
    Fake.Pty.set_cwd(res.pty, "/nonexistent-herdr-wf-test/proj")

    start_supervised!({WorkspaceFacts, enabled: true, name: :workspace_facts_wiring, poll_ms: 10})
    wait_until(fn -> hd(Store.snapshot().session.workspaces).name == "proj" end)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
