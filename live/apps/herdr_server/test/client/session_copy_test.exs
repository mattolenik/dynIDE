defmodule HerdrServer.Client.SessionCopyTest do
  # Client.Session's copy mode against the fake kernel: prefix [ enters it per client,
  # keys move and copy, leaving restores the scroll, focus moving away ends it.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.{Event, Protocol, Scene}
  alias HerdrServer.App.Store
  alias HerdrServer.Client.CopyMode
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows

  setup do
    reset()
    on_exit(&reset/0)
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

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

  defp scene_until(c, fun) do
    assert_receive {^c, {:scene, s}}, 500
    if fun.(s), do: s, else: scene_until(c, fun)
  end

  defp vt(id) do
    {:ok, %{vt: vt}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    vt
  end

  defp output(id, text) do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(id))
    Fake.Pty.output(pty, text)
    assert eventually(fn -> match?({_, _, %{x: x}} when x > 0, Rows.fetch(id)) end)
  end

  defp input(s, c, ev) do
    seq = System.unique_integer([:positive])
    send(s, {:input, c, seq, ev})
    assert_receive {^c, {:ack, ^seq}}, 500
  end

  defp keys(s, c, ks), do: Enum.each(ks, &input(s, c, key(&1)))
  defp key({k, mods}), do: Event.key(k, mods)
  defp key(k), do: Event.key(k)

  defp mode_text(scene), do: Scene.Node.find(scene.chrome, [:status, :mode]).text
  defp overlays(scene, id), do: Enum.find(scene.panes, &(&1.id == id)).overlays

  defp eventually(fun, n \\ 50) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && eventually(fun, n - 1)
    end
  end

  test "prefix [ enters copy mode for this client only; v y copies and leaves" do
    {a, sa} = client()
    {b, sb} = client()
    scene_until(a, &(&1.panes != []))
    output(1, "hello")

    keys(sa, a, [{"b", [:ctrl]}, "["])
    assert_received {^a, {:input_mode, :copy}}
    assert %{mode: :copy, copy: %CopyMode{pane: 1, cursor: {5, 0}}} = :sys.get_state(sa)
    assert %{mode: :terminal, copy: nil} = :sys.get_state(sb)

    scene = scene_until(a, &(mode_text(&1) == "COPY"))
    assert [%{kind: :copy_cursor, args: %{at: {5, 0}}}] = overlays(scene, 1)
    refute_received {^b, {:input_mode, _}}

    keys(sa, a, ["0", "v", "l", "l", "l", "l"])
    scene = scene_until(a, &(length(overlays(&1, 1)) == 2))
    assert Enum.any?(overlays(scene, 1), &(&1.kind == :selection))

    keys(sa, a, ["y"])
    assert_receive {^a, {:clipboard, %{text: "hello", source: :selection}}}, 500
    assert_receive {^a, {:input_mode, :terminal}}, 500
    assert %{mode: :terminal, copy: nil} = :sys.get_state(sa)
    scene = scene_until(a, &(mode_text(&1) == "TERMINAL"))
    assert overlays(scene, 1) == []

    # the y release after leaving does not reach the pane
    input(sa, a, Event.key("y", [], event: :release))
    refute MapSet.member?(:sys.get_state(sa).swallow, "y")
  end

  test "g scrolls to the top of history; q restores the bottom" do
    {a, sa} = client()
    scene_until(a, &(&1.panes != []))
    :ok = Fake.Vt.set_history(vt(1), for(i <- 1..40, do: "h#{i}"))
    bottom = Fake.Vt.scrollbar(vt(1)).offset
    assert bottom > 0

    keys(sa, a, [{"b", [:ctrl]}, "[", "g"])
    assert eventually(fn -> Fake.Vt.scrollbar(vt(1)).offset == 0 end)
    assert %{copy: %CopyMode{cursor: {_, 0}}} = :sys.get_state(sa)

    keys(sa, a, ["q"])
    assert_receive {^a, {:input_mode, :terminal}}, 500
    assert eventually(fn -> Fake.Vt.scrollbar(vt(1)).offset == bottom end)
  end

  test "a search runs off the session: it answers during a 20_000-row miss" do
    {a, sa} = client()
    scene_until(a, &(&1.panes != []))
    :ok = Fake.Vt.set_history(vt(1), for(i <- 1..20_000, do: "h#{i}"))

    keys(sa, a, [{"b", [:ctrl]}, "[", "?", "z", "q", "x"])
    t0 = System.monotonic_time(:millisecond)
    keys(sa, a, [:enter])
    assert %{copy: %CopyMode{pending: id, task: task}} = :sys.get_state(sa)
    assert is_integer(id) and Process.alive?(task)

    {us, %{copy: %{task: ^task}}} = :timer.tc(fn -> :sys.get_state(sa) end)
    assert us < 50_000

    assert_receive {^a, {:notice, %{text: "no match for zqx"}}}, 30_000
    took = System.monotonic_time(:millisecond) - t0
    assert %{copy: %CopyMode{pending: nil, match: nil, task: nil}} = :sys.get_state(sa)
    # the miss outlasted the ping by far: the session was not waiting on it
    assert took > 50
  end

  test "a newer search cancels the older; leaving copy mode cancels it too" do
    {a, sa} = client()
    scene_until(a, &(&1.panes != []))
    :ok = Fake.Vt.set_history(vt(1), for(i <- 1..20_000, do: "h#{i}"))

    keys(sa, a, [{"b", [:ctrl]}, "[", "?", "z", :enter])
    %{copy: %{pending: old, task: first}} = :sys.get_state(sa)
    ref = Process.monitor(first)
    keys(sa, a, ["?", "y", :enter])
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 500
    %{copy: %{pending: new, task: second}} = :sys.get_state(sa)
    assert new > old

    # the stale result of the old id is dropped
    send(sa, {:copy_search, old, {:ok, nil}})
    assert %{copy: %{pending: ^new}} = :sys.get_state(sa)

    ref = Process.monitor(second)
    keys(sa, a, ["q"])
    assert_receive {:DOWN, ^ref, :process, ^second, :killed}, 500
    assert %{copy: nil} = :sys.get_state(sa)
    refute_received {^a, {:notice, %{text: "no match" <> _}}}
  end

  test "focus moving off the copy pane ends copy mode" do
    {a, sa} = client()
    {b, sb} = client()
    keys(sa, a, [{"b", [:ctrl]}, "v"])
    assert eventually(fn -> Store.snapshot().focus.pane == 2 end)

    keys(sa, a, [{"b", [:ctrl]}, "["])
    assert %{mode: :copy, copy: %CopyMode{pane: 2}} = :sys.get_state(sa)

    keys(sb, b, [{"b", [:ctrl]}, "h"])
    assert_receive {^a, {:input_mode, :terminal}}, 500
    assert %{mode: :terminal, copy: nil} = :sys.get_state(sa)
  end

  test "the copy pane closing ends copy mode" do
    {a, sa} = client()
    {b, sb} = client()
    keys(sa, a, [{"b", [:ctrl]}, "v"])
    assert eventually(fn -> Store.snapshot().focus.pane == 2 end)
    keys(sa, a, [{"b", [:ctrl]}, "["])
    assert %{mode: :copy, copy: %CopyMode{pane: 2}} = :sys.get_state(sa)

    keys(sb, b, [{"b", [:ctrl]}, "x"])
    assert_receive {^a, {:input_mode, :terminal}}, 500
    assert eventually(fn -> map_size(Store.snapshot().session.panes) == 1 end)
    assert %{mode: :terminal, copy: nil} = :sys.get_state(sa)
    assert Process.alive?(sa)
  end

  test "a re-attach with a mirrored :copy mode starts outside copy mode" do
    me = self()
    on_exit(fn -> HerdrServer.Mirror.delete({:client, me}) end)

    HerdrServer.Mirror.put({:client, me}, %{
      viewports: %{},
      hover: nil,
      mode: :copy,
      swallow: MapSet.new()
    })

    info = %{
      kind: :term,
      transport: :ref,
      size: %{cols: 80, rows: 24},
      cell_px: nil,
      caps: %{},
      client: me
    }

    {:ok, session, _} = GenServer.call(Protocol.endpoint(), {:attach, info})
    assert %{mode: :terminal, copy: nil} = :sys.get_state(session)
    refute_received {:input_mode, _}
  end
end
