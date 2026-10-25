defmodule HerdrServer.Pane.ServerGraphicsTest do
  # Kitty placements: Pane.Server -> Pane.Facts -> the session's scene; Client.Images.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.{Protocol, Scene}
  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Client.Images
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.{Facts, Rows}

  setup do
    reset()
    on_exit(&reset/0)
    {c, reply} = client()
    # this test process sees what every client session sees
    {:ok, _} = Registry.register(HerdrServer.Client.Registry, :clients, nil)
    scene(c)
    drain()
    %{c: c, reply: reply}
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
    assert_receive {:attached, ^pid, reply}
    {pid, reply}
  end

  defp relay(parent) do
    receive do
      msg -> send(parent, {self(), msg})
    end

    relay(parent)
  end

  defp scene(c) do
    assert_receive {^c, {:scene, s}}, 500
    assert Scene.validate(s) == :ok
    s
  end

  defp scene_until(c, fun) do
    s = scene(c)
    if fun.(s), do: s, else: scene_until(c, fun)
  end

  defp drain do
    receive do
      {:pane_facts, _} -> drain()
      {:pane_damage, _, _} -> drain()
    after
      50 -> :ok
    end
  end

  defp res(id), do: elem(Fake.Keeper.lookup(Rows.kernel_id(id)), 1)

  defp g(over \\ %{}) do
    Map.merge(
      %{
        image: {7, 42},
        placement: 3,
        x: 0,
        y: 0,
        cols: 4,
        rows: 2,
        x_off: 0,
        y_off: 0,
        src: {0, 0, 0, 0},
        px: {0, 0},
        z: 0,
        size: {2, 1},
        format: :rgba,
        bytes: 8
      },
      over
    )
  end

  @img %{format: :rgba, width: 2, height: 1, bytes: 8, data: <<0::64>>}

  defp pane(scene, id), do: Enum.find(scene.panes, &(&1.id == id))

  test "a placement reaches Facts and the next scene; unchanged ones send no facts", %{c: c} do
    :ok = Fake.Vt.set_graphics(res(1).vt, [g()])
    Fake.Pty.output(res(1).pty, "x")
    assert_receive {:pane_facts, 1}, 500
    assert Facts.graphics(1) == [g()]
    assert pane(scene_until(c, &(pane(&1, 1).graphics != [])), 1).graphics == [g()]

    Fake.Pty.output(res(1).pty, "y")
    assert_receive {:pane_damage, 1, _}, 500
    refute_receive {:pane_facts, 1}, 100

    # a removed placement is announced too
    :ok = Fake.Vt.set_graphics(res(1).vt, [])
    Fake.Pty.output(res(1).pty, "z")
    assert_receive {:pane_facts, 1}, 500
    assert Facts.graphics(1) == []
    assert scene_until(c, &(pane(&1, 1).graphics == [])) |> pane(1)
  end

  test "a pane on a hidden tab is not in the scene, so its graphics are not", %{c: c} do
    :ok = Store.run({Actions, :new_tab, []}, %{cols: 80, rows: 24})
    scene_until(c, &match?([%{id: 2}], &1.panes))
    :ok = Fake.Vt.set_graphics(res(1).vt, [g()])
    Fake.Pty.output(res(1).pty, "x")
    :ok = Fake.Vt.set_graphics(res(2).vt, [g(%{placement: 9})])
    Fake.Pty.output(res(2).pty, "x")
    s = scene_until(c, &(pane(&1, 2).graphics != []))
    assert [%{id: 2, graphics: [%{placement: 9}]}] = s.panes
  end

  test "closing a pane drops its graphics", %{c: c} do
    :ok = Store.run({Actions, :new_tab, []}, %{cols: 80, rows: 24})
    scene_until(c, &match?([%{id: 2}], &1.panes))
    :ok = Fake.Vt.set_graphics(res(2).vt, [g()])
    Fake.Pty.output(res(2).pty, "x")
    assert_receive {:pane_facts, 2}, 500
    assert Facts.graphics(2) == [g()]
    :ok = Store.run({Actions, :close_pane, []}, %{cols: 80, rows: 24})
    scene_until(c, &match?([%{id: 1}], &1.panes))
    assert Facts.graphics(2) == []
  end

  test "Images.fetch serves the vt's image, nil for an unknown pane or image" do
    :ok = Fake.Vt.set_graphics(res(1).vt, [g()], %{7 => @img})
    assert Images.fetch(1, 7) == @img
    assert Images.fetch(1, 8) == nil
    assert Images.fetch(999, 7) == nil
  end

  test "the attach reply carries the images MFA and validates", %{reply: reply} do
    assert Protocol.validate_attach_reply(reply) == :ok
    assert {:ok, _, %{images: {Images, :fetch, []}}} = reply
  end
end
