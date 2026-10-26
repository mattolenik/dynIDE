defmodule DynideServer.Persist.RestorePlanTest do
  use ExUnit.Case, async: true

  alias DynideServer.AgentResume
  alias DynideServer.App.Actions
  alias DynideServer.Config
  alias DynideServer.Layout
  alias DynideServer.Persist.RestorePlan

  # two tabs of two panes: 1, 2 in tab 1 (horizontal) and 3, 4 in tab 2 (vertical)
  defp app do
    {app, _} = Actions.init(%{cols: 80, rows: 24})
    {app, _} = Actions.split(app, :horizontal)
    {app, _} = Actions.new_tab(app)
    {app, _} = Actions.split(app, :vertical)
    app
  end

  defp rects(app, tab_id) do
    s = app.session
    [ws] = s.workspaces
    tab = Enum.find(ws.tabs, &(&1.id == tab_id))
    Map.new(Layout.rects(tab.layout, s.area, Layout.opts(tab, app.ui)), &{&1.id, &1.rect})
  end

  test "one spawn per pane of every tab, sized to that tab's rects" do
    app = app()
    spawns = RestorePlan.spawns(app, %{}, %{}, fn _ -> true end)
    assert Enum.map(spawns, &elem(&1, 1)) |> Enum.sort() == [1, 2, 3, 4]

    want = Map.merge(rects(app, 1), rects(app, 2))

    for {:spawn, id, size, opts} <- spawns do
      assert size == %{cols: want[id].w, rows: want[id].h}
      assert opts == %{cwd: nil, replay: nil}
    end

    # the tabs split differently, so the sizes really come from each tab's own layout
    sizes = Map.new(spawns, fn {:spawn, id, size, _} -> {id, size} end)
    assert sizes[1] != sizes[3]
  end

  test "a deleted cwd falls back to its nearest existing ancestor, else nil" do
    app = app()
    facts = %{1 => %{cwd: "/a/b/c"}, 2 => %{cwd: "/a"}, 3 => %{cwd: "/x/y"}, 4 => %{cwd: nil}}
    exists? = &(&1 == "/a")
    cwds = Map.new(RestorePlan.spawns(app, facts, %{}, exists?), &{elem(&1, 1), elem(&1, 3).cwd})
    assert cwds == %{1 => "/a", 2 => "/a", 3 => nil, 4 => nil}
  end

  test "replay is the scrollback with an attribute reset and a new line appended" do
    spawns = RestorePlan.spawns(app(), %{}, %{2 => "hi\e[31m"}, fn _ -> true end)
    replays = Map.new(spawns, &{elem(&1, 1), elem(&1, 3).replay})
    assert replays == %{1 => nil, 2 => "hi\e[31m\e[0m\r\n", 3 => nil, 4 => nil}
  end

  describe "resumes/2" do
    defp with_sessions(app) do
      {app, []} = AgentResume.put(app, 1, %{agent: "claude", kind: :id, value: "s 1"})
      {app, []} = AgentResume.put(app, 3, %{agent: "x", kind: :argv, value: ["x", "--go"]})
      # not resumable: an unknown agent's id
      {app, []} = AgentResume.put(app, 4, %{agent: "nope", kind: :id, value: "z"})
      app
    end

    # what the restored ui says; never read (`[session]` is file-only)
    defp persisted_on(app),
      do:
        put_in(app.ui.session, %{
          resume_agents_on_restore: true,
          startup_per_agent_delay_ms: 9
        })

    defp cfg(toml) do
      path = Path.join(System.tmp_dir!(), "rp#{System.unique_integer([:positive])}.toml")
      File.write!(path, toml)
      on_exit(fn -> File.rm(path) end)
      Config.load(path)
    end

    @on "[session]\nresume_agents_on_restore = true\n"

    test "off: no config, a config without the key, or only a persisted true" do
      app = with_sessions(app())
      assert RestorePlan.resumes(app, nil) == []
      assert RestorePlan.resumes(persisted_on(app), nil) == []
      assert RestorePlan.resumes(persisted_on(app), cfg("[session]\n")) == []
      assert RestorePlan.resumes(persisted_on(app), cfg("[ui]\n")) == []
    end

    test "on: one raw write per resumable pane, n * delay apart" do
      cfg = cfg(@on <> "startup_per_agent_delay_ms = 250\n")

      assert RestorePlan.resumes(with_sessions(app()), cfg) == [
               {250, {:paste_raw, 1, "'claude' '--resume' 's 1'\r"}},
               {500, {:paste_raw, 3, "'x' '--go'\r"}}
             ]

      # the default delay, not the persisted one
      assert [{500, _}, {1000, _}] =
               RestorePlan.resumes(persisted_on(with_sessions(app())), cfg(@on))

      assert [{0, _}, {0, _}] =
               RestorePlan.resumes(
                 with_sessions(app()),
                 cfg(@on <> "startup_per_agent_delay_ms = 0\n")
               )
    end

    test "an out-of-range delay keeps the default with a diagnostic" do
      cfg = cfg(@on <> "startup_per_agent_delay_ms = 60001\n")
      {_, ui, [diag]} = Config.apply(cfg, app().ui.keybinds, app().ui)
      assert ui.session.startup_per_agent_delay_ms == 500 and diag =~ "startup_per_agent_delay_ms"
      assert [{500, _}, {1000, _}] = RestorePlan.resumes(with_sessions(app()), cfg)
    end
  end
end
