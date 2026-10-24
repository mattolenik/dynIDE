defmodule HerdrTerm.Client.Term.RenderTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias HerdrScene.Fixture
  alias HerdrTerm.{Cells, Client}
  alias HerdrTerm.Client.Term.Theme
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

  # the pane's first row: screen row 0 is the tab bar
  defp top(tty), do: Enum.at(Blit.screen(tty), 1)

  defp set_rows(agent, id, text),
    do: Agent.update(agent, &Map.put(&1, id, {0, {Cells.text(text, @s)}, nil}))

  test "a scene renders a full repaint", %{render: render, tty: tty, rows: rows} do
    set_rows(rows, 1, "hello")
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}
    assert top(tty) =~ "hello"
  end

  test "a failing Compose drops the frame and keeps the render state", %{render: render} do
    # a broken theme fails the chrome layout, which keeps the (here broken) old one
    broken = %{base: :broken, top: %{}, hits: [], dim: false}
    :sys.replace_state(render, &%{&1 | theme: :broken, chrome: broken})
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    refute_receive {:frame, _, _}, 100
    assert %{theme: :broken, scene: %{}, chrome: ^broken} = :sys.get_state(render)

    # fixed with no new damage or scene: the dropped frame is retried in full, and the
    # retry recomputes the layout for the new theme
    :sys.replace_state(render, &%{&1 | theme: Theme.default()})
    assert_receive {:frame, _, %{repaint: true}}, 1500
    assert %{base: %{23 => _}} = :sys.get_state(render).chrome
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
    assert top(tty) =~ "hello"
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
    assert top(tty) =~ "v50"
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

  # a re-attached session re-seeds a mirrored mode and tells the client pid (Render)
  test "a session's {:input_mode, mode} reaches Input after the attach reset", %{render: r} do
    send(r, {:input_mode, :prefix})
    input = Client.whereis(:sys.get_state(r).id, :input)
    assert eventually(fn -> :sys.get_state(input).mode == :prefix end)
  end

  defp eventually(f, n \\ 50) do
    cond do
      f.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && eventually(f, n - 1)
    end
  end

  describe "chrome layout" do
    setup %{render: render} do
      input = Client.whereis(:sys.get_state(render).id, :input)
      :erlang.trace(input, true, [:receive])
      on_exit(fn -> if Process.alive?(input), do: :erlang.trace(input, false, [:receive]) end)
      %{input: input}
    end

    test "hits go to Input when they change, once", %{render: render, input: input} do
      sc = Fixture.load("two_tabs_80x24")
      send(render, {:scene, sc})
      assert_receive {:trace, ^input, :receive, {:chrome_hits, hits}}
      assert Enum.any?(hits, &(&1.path == [:tabs, :new_tab]))
      assert :sys.get_state(render).chrome.hits == hits

      # same hits (only the status title changed): no message, layout recomputed
      [sidebar, tabs, status] = sc.chrome.children
      title = %{status | children: Enum.map(status.children, &retitle/1)}
      send(render, {:scene, %{sc | chrome: %{sc.chrome | children: [sidebar, tabs, title]}}})
      assert_receive {:frame, _, _}
      refute_receive {:trace, ^input, :receive, {:chrome_hits, _}}, 50

      assert :sys.get_state(render).chrome_key |> elem(0) |> inspect(limit: :infinity) =~
               "zz-title"

      send(render, {:scene, Fixture.load("single_pane_80x24")})
      assert_receive {:trace, ^input, :receive, {:chrome_hits, hits2}}
      assert hits2 != hits
    end

    test "a failing layout keeps the old one and is retried", %{render: render} do
      sc = Fixture.load("two_tabs_80x24")
      send(render, {:scene, sc})
      assert_receive {:frame, _, _}
      %{chrome: layout, chrome_key: key} = :sys.get_state(render)
      :sys.replace_state(render, &%{&1 | theme: :broken})
      send(render, {:scene, %{sc | size: %{cols: 81, rows: 24}}})

      # the failed key is not stored: the old layout and key stay
      assert eventually(fn -> :sys.get_state(render).scene.size.cols == 81 end)
      assert %{chrome: ^layout, chrome_key: ^key} = :sys.get_state(render)

      # fixed, with no new scene or damage: the retry re-attempts the layout
      :sys.replace_state(render, &%{&1 | theme: Theme.default()})

      assert eventually(
               fn -> :sys.get_state(render).chrome_key |> elem(1) |> Map.get(:cols) == 81 end,
               150
             )
    end

    test "an equal chrome stores the new scene's term as the key", %{render: render} do
      sc = Fixture.load("two_tabs_80x24")
      send(render, {:scene, sc})
      assert_receive {:frame, _, _}
      # an equal chrome arrives as a separate term (each message is a copy)
      send(render, {:scene, sc})
      test = self()

      :sys.replace_state(render, fn s ->
        send(test, {:same, :erts_debug.same(elem(s.chrome_key, 0), s.scene.chrome)})
        s
      end)

      assert_receive {:same, true}
    end
  end

  defp retitle(%{id: :title} = n), do: %{n | text: "zz-title"}
  defp retitle(n), do: n

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
    assert top(tty) =~ "seeded"
    send(render, {:scene, %{inline.([]) | chrome: nil}})
    assert_receive {:frame, _, _}
    assert top(tty) =~ "seeded"
  end

  test "scene with {:inline, [{1, b}]} after a full pane keeps row 0", %{render: render, tty: tty} do
    scene = Fixture.load("single_pane_80x24")
    [p] = scene.panes
    inline = fn rows -> %{scene | panes: [%{p | rows: {:inline, rows}}]} end
    send(render, {:scene, inline.([{0, Cells.text("rowzero", @s)}])})
    assert_receive {:frame, _, _}
    send(render, {:scene, inline.([{1, Cells.text("rowone", @s)}])})
    assert_receive {:frame, _, _}
    [r0, r1 | _] = Blit.screen(tty)
    assert r0 =~ "rowzero" and r1 =~ "rowone"
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
    assert top(tty) =~ "inline"
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
