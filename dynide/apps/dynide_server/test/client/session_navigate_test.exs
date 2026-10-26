defmodule DynideServer.Client.SessionNavigateTest do
  # Client.Session's navigate mode: prefix w previews workspaces for this client only,
  # Enter switches, Esc leaves the active workspace unchanged.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.{Event, Protocol, Scene}
  alias DynideServer.App.{Actions, Store}

  @size %{cols: 80, rows: 24, cell_px: nil}

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
          size: Map.take(@size, [:cols, :rows]),
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

  defp keys(s, c, ks) do
    for k <- ks do
      seq = System.unique_integer([:positive])
      {k, mods} = if is_tuple(k), do: k, else: {k, []}
      send(s, {:input, c, seq, Event.key(k, mods)})
      assert_receive {^c, {:ack, ^seq}}, 500
    end
  end

  defp selected(scene) do
    for %{id: {:workspace, id}, props: %{selected: true}} <-
          Scene.Node.find(scene.chrome, [:sidebar, :spaces, :list]).children,
        do: id
  end

  defp mode_text(scene), do: Scene.Node.find(scene.chrome, [:status, :mode]).text

  test "prefix w previews from the active workspace; Down wraps; Enter switches" do
    {a, sa} = client()
    {_b, sb} = client()
    scene_until(a, &(&1.panes != []))
    Store.run({Actions, :new_workspace, []}, @size)
    active = Store.snapshot().session.active_workspace
    [first, ^active] = Enum.map(Store.snapshot().session.workspaces, & &1.id)

    keys(sa, a, [{"b", [:ctrl]}, "w"])
    assert_received {^a, {:input_mode, :navigate}}
    assert %{mode: :navigate, navigate: %{at: 1}} = :sys.get_state(sa)
    assert %{mode: :terminal, navigate: nil} = :sys.get_state(sb)
    scene = scene_until(a, &(mode_text(&1) == "NAVIGATE"))
    assert selected(scene) == [active]

    keys(sa, a, [:down])
    assert selected(scene_until(a, &(selected(&1) == [first]))) == [first]
    assert Store.snapshot().session.active_workspace == active

    keys(sa, a, [:enter])
    assert_receive {^a, {:input_mode, :terminal}}, 500
    assert Store.snapshot().session.active_workspace == first
    assert %{navigate: nil} = :sys.get_state(sa)
    assert selected(scene_until(a, &(mode_text(&1) == "TERMINAL"))) == []
  end

  test "Esc leaves the workspace unchanged" do
    {a, sa} = client()
    scene_until(a, &(&1.panes != []))
    Store.run({Actions, :new_workspace, []}, @size)
    active = Store.snapshot().session.active_workspace

    keys(sa, a, [{"b", [:ctrl]}, "w", "j", :escape])
    assert_receive {^a, {:input_mode, :terminal}}, 500
    assert Store.snapshot().session.active_workspace == active
    assert %{mode: :terminal, navigate: nil} = :sys.get_state(sa)
  end
end
