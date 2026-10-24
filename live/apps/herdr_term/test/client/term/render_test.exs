defmodule HerdrTerm.Client.Term.RenderTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias HerdrScene.Fixture
  alias HerdrTerm.{Cells, Client}
  alias HerdrTerm.Kernel.Fake.Blit
  alias HerdrTerm.Test.FakeServer

  @s Cells.style([])

  def rows(id, agent) do
    Agent.get(agent, fn m ->
      send(Map.get(m, :test), {:fetched, id})
      if Map.get(m, id) == :boom, do: raise("rows boom"), else: Map.get(m, id)
    end)
  end

  setup do
    test = self()
    rows = start_supervised!({Agent, fn -> %{test: test} end})
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, [rows]})
    sup = start_supervised!({Client, endpoint: ep})
    assert_receive {:attached, _, session}
    tty = Client.tty(sup)
    Blit.subscribe_frames(tty, self())
    %{render: Client.render(sup), tty: tty, rows: rows, session: session}
  end

  defp set_rows(agent, id, text),
    do: Agent.update(agent, &Map.put(&1, id, {0, {Cells.text(text, @s)}, nil}))

  test "a scene renders a full repaint", %{render: render, tty: tty, rows: rows} do
    set_rows(rows, 1, "hello")
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
    assert hd(Blit.screen(tty)) =~ "hello"
  end

  test "a failing Compose drops the frame and keeps the render state", %{render: render} do
    :sys.replace_state(render, &%{&1 | theme: :broken})
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    refute_receive {:frame, _, _}, 100
    assert %{theme: :broken, scene: %{}} = :sys.get_state(render)
  end

  test "a failing rows fetch keeps the cached rows and still renders", %{
    render: render,
    tty: tty,
    rows: rows
  } do
    set_rows(rows, 1, "hello")
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
    Agent.update(rows, &Map.put(&1, 1, :boom))
    send(render, {:damage, 1, 2})
    assert_receive {:frame, _, _}
    assert hd(Blit.screen(tty)) =~ "hello"
  end

  test "damage is paced and the last frame has the last rows", %{
    render: render,
    tty: tty,
    rows: rows
  } do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}

    for n <- 1..50 do
      set_rows(rows, 1, "v#{n}")
      send(render, {:damage, 1, n})
    end

    assert_receive {:frame, _, %{repaint: false}}
    Process.sleep(50)
    assert length(drain()) <= 1
    assert hd(Blit.screen(tty)) =~ "v50"
  end

  test "a dead session re-attaches and repaints", %{render: render, session: session} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
    send(render, {:damage, 1, 1})
    assert_receive {:frame, _, %{repaint: false}}
    Process.exit(session, :kill)
    assert_receive {:attached, _, session2}
    assert session2 != session
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
  end

  test "a scene re-fetches only new panes and panes whose layout_gen changed", %{
    render: render,
    rows: rows
  } do
    set_rows(rows, 1, "a")
    scene = Fixture.load("single_pane_80x24")
    send(render, {:scene, scene})
    assert_receive {:frame, _, _}
    assert_received {:fetched, 1}
    send(render, {:scene, %{scene | chrome: nil}})
    assert_receive {:frame, _, _}
    refute_received {:fetched, _}
    [p] = scene.panes
    {:ref, 1, lg} = p.rows
    send(render, {:scene, %{scene | panes: [%{p | rows: {:ref, 1, lg + 1}}]}})
    assert_receive {:frame, _, _}
    assert_received {:fetched, 1}
  end

  test "the host cursor is the focused pane's cached cursor in its rect", %{
    render: render,
    rows: rows
  } do
    c = %{x: 3, y: 2, shape: :bar, visible: true}
    Agent.update(rows, &Map.put(&1, 1, {0, {Cells.text("x", @s)}, c}))
    scene = Fixture.load("single_pane_80x24")
    send(render, {:scene, scene})
    [%{rect: r}] = scene.panes
    want = {r.x + 3, r.y + 2}
    assert_receive {:frame, _, %{cursor: ^want}}
  end

  test "inline scene rows replace the cache, empty inline rows keep it", %{
    render: render,
    tty: tty
  } do
    scene = Fixture.load("single_pane_80x24")
    [p] = scene.panes
    inline = fn rows -> %{scene | panes: [%{p | rows: {:inline, rows}}]} end
    send(render, {:scene, inline.([{0, Cells.text("seeded", @s)}])})
    assert_receive {:frame, _, _}
    assert hd(Blit.screen(tty)) =~ "seeded"
    send(render, {:scene, %{inline.([]) | chrome: nil}})
    assert_receive {:frame, _, _}
    assert hd(Blit.screen(tty)) =~ "seeded"
  end

  test ":repaint forces a full repaint", %{render: render} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
    send(render, :repaint)
    assert_receive {:frame, _, %{repaint: true}}
  end

  test "a scene of another size repaints", %{render: render} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: false}}
    send(render, {:scene, Fixture.load("two_pane_split_120x40")})
    assert_receive {:frame, _, %{repaint: true}}
  end

  test "inline rows seed the cache; notices are kept", %{render: render, tty: tty} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, _}
    send(render, {:rows, 1, 0, [{0, Cells.text("inline", @s)}]})
    assert_receive {:frame, _, %{repaint: false}}
    assert hd(Blit.screen(tty)) =~ "inline"
    notice = %{level: :info, text: "hi"}
    send(render, {:notice, notice})
    assert :sys.get_state(render).notice == notice
  end

  test "attach retries until the endpoint exists" do
    ep = FakeServer.unique_name()
    start_supervised!({Client, endpoint: ep}, id: :late)
    refute_receive {:attached, _, _}, 80
    FakeServer.start(self(), ep, {__MODULE__, :rows, [nil]})
    assert_receive {:attached, _, _}, 200
  end

  defp drain do
    receive do
      {:frame, _, info} -> [info | drain()]
    after
      0 -> []
    end
  end
end
