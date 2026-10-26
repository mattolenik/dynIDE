defmodule DynideServer.Client.SessionPointerTest do
  # Client.Session's pointer path against the fake kernel: selections stay per client,
  # copy reaches the client, stale state is dropped, pane bells and clipboard forward.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.{Cell, Event, Protocol}
  alias DynideServer.App.Store
  alias DynideServer.Client.{Pointer, PointerIo, Selection, State}
  alias DynideServer.Kernel.Fake
  alias DynideServer.Pane.{Facts, Rows, Server}
  alias DynideServer.Plugins.{Install, Menu, Runtime}
  alias DynideServer.Test.PluginDirs
  alias DynideServer.View.Overlays

  setup do
    reset()
    on_exit(&reset/0)
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(DynideServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(DynideServer.Client.Supervisor, pid)

    Store.reset()
  end

  defp client do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: %{cols: 80, rows: 24},
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, self(), GenServer.call(Protocol.endpoint(), {:attach, info})})
        relay(parent)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, ^pid, {:ok, session, _}}
    {pid, session}
  end

  defp relay(parent) do
    receive do
      msg -> send(parent, {self(), msg})
    end

    relay(parent)
  end

  defp scene(c) do
    assert_receive {^c, {:scene, s}}, 500
    s
  end

  defp scene_until(c, fun) do
    s = scene(c)
    if fun.(s), do: s, else: scene_until(c, fun)
  end

  # the newest scene the client got (waits for the first one)
  defp last_scene(c, s \\ nil) do
    receive do
      {^c, {:scene, s}} -> last_scene(c, s)
    after
      if(s, do: 50, else: 500) -> s
    end
  end

  defp vt(id) do
    {:ok, %{vt: vt}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    vt
  end

  # program output, and wait until the pane's rows show `text` on row 0
  defp output(id, text) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    Fake.Pty.output(pty, text)

    assert eventually(fn ->
             case Rows.fetch(id) do
               {_, rows, _} -> row_text(elem(rows, 0)) =~ text
               nil -> false
             end
           end)
  end

  defp row_text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))

  # sends one input and waits for its ack
  defp input(s, c, ev) do
    seq = System.unique_integer([:positive])
    send(s, {:input, c, seq, ev})
    assert_receive {^c, {:ack, ^seq}}, 500
  end

  defp mouse(kind, button, x, y, mods \\ []),
    do: {:mouse, %{kind: kind, button: button, x: x, y: y, mods: mods, px: nil}}

  defp pointer(s), do: :sys.get_state(s).pointer

  defp selection_overlays(scene),
    do: for(p <- scene.panes, o <- p.overlays, o.kind == :selection, do: {p.id, o})

  defp rect(scene, id), do: Enum.find(scene.panes, &(&1.id == id)).rect

  defp eventually(fun, n \\ 50) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && eventually(fun, n - 1)
    end
  end

  test "two_clients_test: a selection is per client; copy sends the text" do
    {a, sa} = client()
    {b, sb} = client()
    r = rect(last_scene(a), 1)
    _ = last_scene(b)
    output(1, "hello")

    input(sa, a, mouse(:press, :left, r.x, r.y))
    input(sa, a, mouse(:drag, :left, r.x + 4, r.y))

    assert %{pane: 1, shown: true, anchor: {0, 0}, head: {4, 0}} = pointer(sa).selection
    assert pointer(sb).selection == nil
    assert [{1, %{args: %{from: {0, 0}, to: {4, 0}}}}] = selection_overlays(last_scene(a))
    assert selection_overlays(last_scene(b) || %{panes: []}) == []

    input(sa, a, mouse(:release, :left, r.x + 4, r.y))
    assert_receive {^a, {:clipboard, %{text: "hello", source: :selection}}}, 500
    assert_receive {^a, {:notice, %{text: "copied to clipboard"}}}, 500
    refute_received {^b, {:clipboard, _}}
    assert pointer(sa).selection == nil
  end

  test "stale_selection_test: closing the pane under a selection drops it" do
    {a, sa} = client()
    _ = last_scene(a)
    input(sa, a, Event.key("b", [:ctrl]))
    input(sa, a, Event.key("v"))
    scene = scene_until(a, &(length(&1.panes) == 2))
    r = rect(scene, 2)

    input(sa, a, mouse(:press, :left, r.x + 1, r.y))
    input(sa, a, mouse(:drag, :left, r.x + 5, r.y + 1))
    assert %{pane: 2, shown: true} = pointer(sa).selection

    input(sa, a, Event.key("b", [:ctrl]))
    input(sa, a, Event.key("x"))
    scene = scene_until(a, &(length(&1.panes) == 1))

    assert Process.alive?(sa)
    assert %{selection: nil, press: nil} = pointer(sa)
    assert selection_overlays(scene) == []

    # the rest of the gesture is harmless
    input(sa, a, mouse(:release, :left, r.x + 5, r.y + 1))
    assert Process.alive?(sa)
  end

  test "an unscrolled selection pane gets the live offset: overlay rows follow the history" do
    {a, sa} = client()
    r = rect(last_scene(a), 1)
    :ok = Fake.Vt.set_history(vt(1), for(i <- 1..10, do: "h#{i}"))
    off = Fake.Vt.scrollbar(vt(1)).offset
    assert off > 0
    refute Facts.scrolled?(1)

    input(sa, a, mouse(:press, :left, r.x, r.y))
    input(sa, a, mouse(:drag, :left, r.x + 4, r.y + 1))

    assert %{anchor: {0, ^off}} = pointer(sa).selection
    assert %{1 => %{scrolled: false, scroll: %{offset: ^off}}} = PointerIo.scene_facts([1], 1)
    scene = scene_until(a, &(selection_overlays(&1) != []))
    assert [{1, %{args: %{from: {0, 0}, to: {4, 1}}}}] = selection_overlays(scene)
  end

  test "scene_facts: unknown selection pane is absent; no kernel resources falls back" do
    assert PointerIo.scene_facts([], 4242) == %{}

    stale = %{total: 50, viewport: 10, offset: 0}
    Facts.put(4243, %{scrolled: false, alt_screen: false, scroll: stale})
    on_exit(fn -> Facts.delete(4243) end)

    assert %{4243 => %{scrolled: false, scroll: ^stale}} = PointerIo.scene_facts([], 4243)

    c = %State{
      pointer: %Pointer{
        selection: %Selection{
          pane: 4243,
          anchor: {0, 40},
          head: {2, 41},
          unit: :char,
          shown: true
        }
      },
      facts: PointerIo.scene_facts([], 4243)
    }

    assert Overlays.pane(4243, %{x: 0, y: 0, w: 20, h: 10}, c) == []
  end

  test "a resize that changes the selection pane's size drops the overlay in the same push" do
    {a, sa} = client()
    r = rect(last_scene(a), 1)
    output(1, "hello")
    input(sa, a, mouse(:press, :left, r.x, r.y))
    input(sa, a, mouse(:drag, :left, r.x + 3, r.y))
    assert selection_overlays(scene_until(a, &(selection_overlays(&1) != []))) != []

    send(sa, {:input, a, 99, {:resize, %{cols: 100, rows: 30, cell_px: nil}}})
    scene = scene_until(a, &(&1.size.cols == 100))
    assert selection_overlays(scene) == []
    assert pointer(sa).selection == nil
  end

  test "a press on an unfocused pane focuses it" do
    {a, sa} = client()
    _ = last_scene(a)
    input(sa, a, Event.key("b", [:ctrl]))
    input(sa, a, Event.key("v"))
    scene = scene_until(a, &(length(&1.panes) == 2))
    assert scene.focus.pane == 2
    r = rect(scene, 1)
    input(sa, a, mouse(:press, :left, r.x + 1, r.y + 1))
    assert scene_until(a, &(&1.focus.pane == 1))
  end

  test "the wheel scrolls a non-tracking pane back" do
    {a, sa} = client()
    r = rect(last_scene(a), 1)
    :ok = Fake.Vt.set_history(vt(1), for(i <- 1..30, do: "h#{i}"))
    input(sa, a, mouse(:scroll, :wheel_up, r.x + 1, r.y + 1))
    assert eventually(fn -> Facts.scrolled?(1) end)
    assert Fake.Vt.scrollbar(vt(1)).offset == 27
  end

  test "dragging onto the top row autoscrolls until the top of the history" do
    {a, sa} = client()
    r = rect(last_scene(a), 1)
    :ok = Fake.Vt.set_history(vt(1), for(i <- 1..10, do: "h#{i}"))
    input(sa, a, mouse(:press, :left, r.x + 1, r.y + 3))
    input(sa, a, mouse(:drag, :left, r.x + 1, r.y))
    assert eventually(fn -> Fake.Vt.scrollbar(vt(1)).offset == 0 end, 100)
    assert %{pane: 1, head: {1, 0}} = pointer(sa).selection
    input(sa, a, mouse(:release, :left, r.x + 1, r.y))
    assert pointer(sa).autoscroll == nil
  end

  test "a double click copies the word and keeps it 500 ms" do
    {a, sa} = client()
    r = rect(last_scene(a), 1)
    output(1, "hello world")

    for kind <- [:press, :release, :press, :release],
        do: input(sa, a, mouse(kind, :left, r.x + 7, r.y))

    assert_receive {^a, {:clipboard, %{text: "world", source: :selection}}}, 500
    assert %{unit: :word, shown: true} = pointer(sa).selection
    assert eventually(fn -> pointer(sa).selection == nil end, 100)
  end

  test "pane bells and child clipboard writes forward; inputs mark the foreground" do
    {a, sa} = client()
    # an attach marks the foreground in handle_continue, after the attach reply: wait
    # for a's first scene (pushed after its mark) before b attaches
    _ = scene(a)
    {_b, sb} = client()
    assert eventually(fn -> Facts.get(:foreground) == sb end)
    send(sa, {:pane_bell, 1})
    assert_receive {^a, {:bell, 1}}, 500
    send(sa, {:pane_clipboard, 1, "x"})
    assert_receive {^a, {:clipboard, %{text: "x", source: :pane}}}, 500
    input(sa, a, mouse(:move, :none, 0, 0))
    assert eventually(fn -> Facts.get(:foreground) == sa end)
  end

  defp pty(id) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    pty
  end

  defp two_panes(a, sa) do
    _ = last_scene(a)
    input(sa, a, Event.key("b", [:ctrl]))
    input(sa, a, Event.key("v"))
    scene_until(a, &(length(&1.panes) == 2))
  end

  defp select(sa, a, r) do
    input(sa, a, mouse(:press, :left, r.x + 1, r.y))
    input(sa, a, mouse(:drag, :left, r.x + 3, r.y))
    assert %{shown: true} = pointer(sa).selection
  end

  describe "selection and hover clearing" do
    test "the alternate screen toggling clears the selection" do
      {a, sa} = client()
      r = rect(last_scene(a), 1)
      select(sa, a, r)
      :ok = Fake.Vt.set_mode(vt(1), :alt_screen, true)
      output(1, "x")
      assert eventually(fn -> pointer(sa).selection == nil end)
    end

    test "app focus moving to another pane clears the selection" do
      {a, sa} = client()
      scene = two_panes(a, sa)
      select(sa, a, rect(scene, 2))
      input(sa, a, Event.key("b", [:ctrl]))
      input(sa, a, Event.key("h"))
      assert scene_until(a, &(&1.focus.pane == 1))
      assert pointer(sa).selection == nil
    end

    test "scrolling the pane clears a hover but keeps the selection" do
      {a, sa} = client()
      r = rect(last_scene(a), 1)
      output(1, "go https://e.com/x")
      :ok = Fake.Vt.set_history(vt(1), for(i <- 1..10, do: "h#{i}"))
      input(sa, a, mouse(:move, :none, r.x + 5, r.y, [:ctrl]))
      assert %{url: "https://e.com/x"} = pointer(sa).hover
      Server.scroll(1, {:delta, -2})
      assert eventually(fn -> pointer(sa).hover == nil end)
    end

    test "a ctrl+move from a link straight onto chrome clears the hover" do
      {a, sa} = client()
      r = rect(last_scene(a), 1)
      # sidebar left of the pane and the row above it (tab bar): outside every pane
      assert r.x > 0 and r.y > 0
      output(1, "go https://e.com/x")

      for {x, y} <- [{0, r.y}, {r.x + 5, r.y - 1}] do
        input(sa, a, mouse(:move, :none, r.x + 5, r.y, [:ctrl]))
        assert %{url: "https://e.com/x"} = pointer(sa).hover
        input(sa, a, mouse(:move, :none, x, y, [:ctrl]))
        assert pointer(sa).hover == nil
      end
    end
  end

  describe "ctrl+click on an osc 8 link" do
    setup do
      {a, sa} = client()
      r = rect(last_scene(a), 1)
      %{a: a, sa: sa, r: r}
    end

    defp link(uri) do
      :ok = Fake.Vt.set_link(vt(1), for(x <- 0..3, do: {x, 0}), 4, uri)
      output(1, "link")

      assert eventually(fn ->
               elem(Rows.fetch(1), 1) |> elem(0) |> Cell.decode_row() |> hd() |> Map.get(:link) ==
                 4
             end)
    end

    defp click(%{a: a, sa: sa, r: r}) do
      input(sa, a, mouse(:press, :left, r.x + 1, r.y, [:ctrl]))
      input(sa, a, mouse(:release, :left, r.x + 1, r.y, [:ctrl]))
    end

    test "a safe url opens on the client", c do
      link("https://e.com/z")
      click(c)
      assert_receive {_, {:open_url, "https://e.com/z"}}, 500
    end

    test "a url a plugin link handler matches runs its action, not the browser", c do
      base = PluginDirs.use_tmp()
      out = Path.join(base, "out")
      start_supervised!({Task.Supervisor, name: DynideServer.Plugins.Tasks})
      start_supervised!(Runtime)
      on_exit(fn -> Menu.put([]) end)

      toml = """
      [[actions]]
      id = "go"
      title = "Go"
      command = ["sh", "-c", "printf '%s|%s' \\"$HERDR_PLUGIN_CLICKED_URL\\" \\"$HERDR_PLUGIN_CLICK_MODIFIERS\\" > #{out}"]
      [[link_handlers]]
      id = "h"
      title = "H"
      pattern = "^https://e\\\\.com/"
      action = "go"
      """

      dir = PluginDirs.plugin(base <> "/p", "t.p", toml)
      {:ok, _} = Install.link(dir, true)
      link("https://e.com/z")
      click(c)
      assert eventually(fn -> File.exists?(out) and File.read!(out) == "https://e.com/z|ctrl" end)
      refute_receive {_, {:open_url, _}}, 100
    end

    test "an unsafe url is dropped", c do
      link("file:///etc/passwd")
      click(c)
      refute_receive {_, {:open_url, _}}, 100
      assert Process.alive?(c.sa)
    end

    test "no link after all: a tracking child gets the press and release", c do
      link(nil)
      :ok = Fake.Vt.set_mode(vt(1), :mouse_normal, true)
      before = pty(1) |> Fake.Pty.writes() |> IO.iodata_to_binary()
      click(c)

      assert eventually(fn ->
               now = pty(1) |> Fake.Pty.writes() |> IO.iodata_to_binary()
               String.replace_prefix(now, before, "") =~ "\e[<"
             end)

      assert pointer(c.sa).swallow_up == nil
    end

    test "no link after all on a non-tracking pane drops the click", c do
      link(nil)
      before = pty(1) |> Fake.Pty.writes()
      click(c)
      assert pty(1) |> Fake.Pty.writes() == before
      assert pointer(c.sa).swallow_up == nil and pointer(c.sa).selection == nil
    end
  end
end
