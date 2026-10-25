defmodule HerdrTerm.Client.Term.RenderTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias HerdrScene.Fixture
  alias HerdrTerm.{Cells, Client}
  alias HerdrTerm.Client.Term.Theme
  alias HerdrTerm.Kernel.Fake.Blit
  alias HerdrTerm.Test.FakeServer

  @s Cells.style([])
  @wait 2_000

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
    assert_receive {:attached, _, session}, @wait
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
    assert_receive {:frame, _, %{repaint: true}}, @wait
    assert top(tty) =~ "hello"
  end

  test "a failing Compose drops the frame and keeps the render state", %{render: render} do
    # a broken theme fails the chrome layout, which keeps the (here broken) old one
    broken = %{base: :broken, top: %{}, hits: [], dim: false}
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, _}, @wait
    :sys.replace_state(render, &%{&1 | theme: :broken, chrome: broken})
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    refute_receive {:frame, _, _}, 100
    assert %{theme: :broken, scene: %{}, chrome: ^broken} = :sys.get_state(render)

    # fixed with no new damage or scene: the dropped frame is retried in full, and the
    # retry recomputes the layout for the new theme
    :sys.replace_state(render, &%{&1 | theme: Theme.default()})
    assert_receive {:frame, _, %{repaint: true}}, @wait
    assert %{base: %{23 => _}} = :sys.get_state(render).chrome
  end

  test "a failing rows fetch keeps the cached rows and still renders", %{
    render: render,
    tty: tty,
    rows: rows
  } do
    set_rows(rows, 1, "hello")
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}, @wait
    Agent.update(rows, &Map.put(&1, 1, :boom))
    send(render, {:damage, 1, 2})
    assert_receive {:frame, _, _}, @wait
    assert top(tty) =~ "hello"
  end

  test "damage is paced and the last frame has the last rows", %{
    render: render,
    tty: tty,
    rows: rows
  } do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}, @wait

    for n <- 1..50 do
      set_rows(rows, 1, "v#{n}")
      send(render, {:damage, 1, n})
    end

    assert_receive {:frame, _, %{repaint: false}}, @wait
    Process.sleep(50)
    assert length(drain()) <= 1
    assert top(tty) =~ "v50"
  end

  test "a dead session re-attaches and repaints", %{render: render, session: session} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}, @wait
    send(render, {:damage, 1, 1})
    assert_receive {:frame, _, %{repaint: false}}, @wait
    Process.exit(session, :kill)
    assert_receive {:attached, _, session2}, @wait
    assert session2 != session
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}, @wait
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

  describe "theme" do
    defp with_theme(sc, props),
      do: %{sc | chrome: %{sc.chrome | props: Map.put(sc.chrome.props, :theme, props)}}

    @latte %{name: "catppuccin-latte", auto_switch: false, light: "x", dark: "x"}

    test "root theme props pick the palette; caps switch auto_switch names", %{render: render} do
      auto = %{name: "nord", auto_switch: true, light: "catppuccin-latte", dark: "dracula"}
      send(render, {:scene, with_theme(Fixture.load("single_pane_80x24"), @latte)})
      assert_receive {:frame, _, _}, @wait
      assert Theme.style(:sys.get_state(render).theme, :accent).fg == {:rgb, 30, 102, 245}

      send(render, {:scene, with_theme(Fixture.load("single_pane_80x24"), auto)})
      assert_receive {:frame, _, _}, @wait
      assert Theme.style(:sys.get_state(render).theme, :accent).fg != {:rgb, 30, 102, 245}

      send(render, {:caps, %{colors: %{bg: {250, 250, 250}}, scheme: nil}})
      assert_receive {:frame, _, _}, @wait
      assert %{appearance: :light} = st = :sys.get_state(render)
      assert Theme.style(st.theme, :accent).fg == {:rgb, 30, 102, 245}
    end

    test "caps before the first scene are kept and applied", %{render: render} do
      send(render, {:caps, %{scheme: :light}})
      assert %{appearance: :light, scene: nil} = :sys.get_state(render)
      auto = %{name: "nord", auto_switch: true, light: "catppuccin-latte", dark: "dracula"}
      send(render, {:scene, with_theme(Fixture.load("single_pane_80x24"), auto)})
      assert_receive {:frame, _, _}, @wait
      assert Theme.style(:sys.get_state(render).theme, :accent).fg == {:rgb, 30, 102, 245}
    end

    test "an unchanged theme and appearance keep the theme term", %{render: render} do
      send(render, {:scene, with_theme(Fixture.load("single_pane_80x24"), @latte)})
      assert_receive {:frame, _, _}, @wait
      %{theme: theme, chrome_key: key} = :sys.get_state(render)
      send(render, {:caps, %{scheme: :dark}})
      send(render, {:scene, with_theme(Fixture.load("single_pane_80x24"), @latte)})
      st = :sys.get_state(render)
      assert st.theme == theme and st.chrome_key == key
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
      assert_receive {:trace, ^input, :receive, {:chrome_hits, hits}}, @wait
      assert Enum.any?(hits, &(&1.path == [:tabs, :new_tab]))
      assert :sys.get_state(render).chrome.hits == hits

      # same hits (only the status title changed): no message, layout recomputed
      [sidebar, tabs, status] = sc.chrome.children
      title = %{status | children: Enum.map(status.children, &retitle/1)}
      send(render, {:scene, %{sc | chrome: %{sc.chrome | children: [sidebar, tabs, title]}}})
      assert_receive {:frame, _, _}, @wait
      refute_receive {:trace, ^input, :receive, {:chrome_hits, _}}, 50

      assert :sys.get_state(render).chrome_key |> elem(0) |> inspect(limit: :infinity) =~
               "zz-title"

      send(render, {:scene, Fixture.load("single_pane_80x24")})
      assert_receive {:trace, ^input, :receive, {:chrome_hits, hits2}}, @wait
      assert hits2 != hits
    end

    test "a failing layout keeps the old one and is retried", %{render: render} do
      sc = Fixture.load("two_tabs_80x24")
      send(render, {:scene, sc})
      assert_receive {:frame, _, _}, @wait
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
      assert_receive {:frame, _, _}, @wait
      # an equal chrome arrives as a separate term (each message is a copy)
      send(render, {:scene, sc})
      test = self()

      :sys.replace_state(render, fn s ->
        send(test, {:same, :erts_debug.same(elem(s.chrome_key, 0), s.scene.chrome)})
        s
      end)

      assert_receive {:same, true}, @wait
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
    assert_receive {:frame, _, _}, @wait
    assert_received {:fetched, 1}
    send(render, {:scene, %{scene | chrome: nil}})
    assert_receive {:frame, _, _}, @wait
    refute_received {:fetched, _}
    [p] = scene.panes
    {:ref, 1, lg} = p.rows
    send(render, {:scene, %{scene | panes: [%{p | rows: {:ref, 1, lg + 1}}]}})
    assert_receive {:frame, _, _}, @wait
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
    assert_receive {:frame, _, %{cursor: ^want}}, @wait
  end

  test "inline scene rows replace the cache, empty inline rows keep it", %{
    render: render,
    tty: tty
  } do
    scene = Fixture.load("single_pane_80x24")
    [p] = scene.panes
    inline = fn rows -> %{scene | panes: [%{p | rows: {:inline, rows}}]} end
    send(render, {:scene, inline.([{0, Cells.text("seeded", @s)}])})
    assert_receive {:frame, _, _}, @wait
    assert top(tty) =~ "seeded"
    send(render, {:scene, %{inline.([]) | chrome: nil}})
    assert_receive {:frame, _, _}, @wait
    assert top(tty) =~ "seeded"
  end

  test "scene with {:inline, [{1, b}]} after a full pane keeps row 0", %{render: render, tty: tty} do
    scene = Fixture.load("single_pane_80x24")
    [p] = scene.panes
    inline = fn rows -> %{scene | panes: [%{p | rows: {:inline, rows}}]} end
    send(render, {:scene, inline.([{0, Cells.text("rowzero", @s)}])})
    assert_receive {:frame, _, _}, @wait
    send(render, {:scene, inline.([{1, Cells.text("rowone", @s)}])})
    assert_receive {:frame, _, _}, @wait
    # the pane's rows sit at its rect (below the M13 tab bar)
    [r0, r1 | _] = Enum.drop(Blit.screen(tty), p.rect.y)
    assert r0 =~ "rowzero" and r1 =~ "rowone"
  end

  test ":repaint forces a full repaint", %{render: render} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}, @wait
    send(render, :repaint)
    assert_receive {:frame, _, %{repaint: true}}, @wait
  end

  test "a scene of another size repaints", %{render: render} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: true}}, @wait
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, %{repaint: false}}, @wait
    send(render, {:scene, Fixture.load("two_pane_split_120x40")})
    assert_receive {:frame, _, %{repaint: true}}, @wait
  end

  test "inline rows seed the cache; notices are kept", %{render: render, tty: tty} do
    send(render, {:scene, Fixture.load("single_pane_80x24")})
    assert_receive {:frame, _, _}, @wait
    send(render, {:rows, 1, 0, [{0, Cells.text("inline", @s)}]})
    assert_receive {:frame, _, %{repaint: false}}, @wait
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
    assert_receive {:attached, _, _}, @wait
  end

  defp drain do
    receive do
      {:frame, _, info} -> [info | drain()]
    after
      0 -> []
    end
  end

  # --- alerts (M13 Task 11) ---

  alias HerdrTerm.Kernel.Fake.Tty

  defp alert_scene(render, props) do
    s = Fixture.load("single_pane_80x24")
    send(render, {:scene, %{s | chrome: %{s.chrome | props: Map.merge(s.chrome.props, props)}}})
    assert_receive {:frame, _, _}, @wait
  end

  defp alert(sound),
    do: %{
      kind: :notification,
      level: :done,
      title: "pi finished",
      body: "w",
      pane: 1,
      sound: sound
    }

  test "terminal delivery writes OSC 9; a sound without a command is BEL", %{
    render: render,
    tty: tty
  } do
    alert_scene(render, %{toast: %{delivery: :terminal}, sound: %{enabled: true, command: nil}})
    send(render, {:alert, alert(:done)})
    _ = :sys.get_state(render)
    assert Tty.written(tty) =~ "\e]9;pi finished: w\a\a"
  end

  @tag :tmp_dir
  test "a sound command runs with the sound name, a missing one logs once", %{
    render: render,
    tty: tty,
    tmp_dir: dir
  } do
    out = Path.join(dir, "out")
    cmd = Path.join(dir, "snd")
    File.write!(cmd, "#!/bin/sh\necho \"$1\" >> '#{out}'\n")
    File.chmod!(cmd, 0o755)
    alert_scene(render, %{toast: %{delivery: :herdr}, sound: %{enabled: true, command: cmd}})
    send(render, {:alert, alert(:request)})
    assert wait_file(out) == "request\n"
    refute Tty.written(tty) =~ "\a"

    alert_scene(render, %{sound: %{enabled: true, command: Path.join(dir, "nope")}})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(render, {:alert, alert(:done)})
        send(render, {:alert, alert(:done)})
        _ = :sys.get_state(render)
      end)

    assert length(String.split(log, "sound command")) == 2
  end

  defp wait_file(path, n \\ 200) do
    case File.read(path) do
      {:ok, s} when s != "" -> s
      _ when n > 0 -> Process.sleep(10) && wait_file(path, n - 1)
      _ -> flunk("#{path} never written")
    end
  end
end
