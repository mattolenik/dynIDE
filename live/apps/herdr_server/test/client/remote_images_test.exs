defmodule HerdrServer.Client.Remote.ImagesTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.{Protocol, Scene}
  alias HerdrServer.App.Store
  alias HerdrServer.Client.Remote
  alias HerdrServer.Client.Remote.{Images, Out}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows

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

  defp scene(graphics_by_pane) do
    %Scene{
      size: %{cols: 10, rows: 5},
      chrome: %Scene.Node{role: :root, props: %{}},
      panes:
        for {id, gs} <- graphics_by_pane do
          %Scene.Pane{
            id: id,
            rect: %{x: 0, y: 0, w: 10, h: 5},
            rows: {:inline, []},
            cursor: nil,
            graphics: gs
          }
        end
    }
  end

  describe "pure" do
    test "missing lists each unsent key once, with a placement" do
      s = scene([{1, [g(), g(%{placement: 4})]}, {2, [g()]}])
      assert [{1, {7, 42}, %{placement: 3}}, {2, {7, 42}, _}] = Images.missing(s, MapSet.new())
      assert Images.missing(s, MapSet.new([{1, {7, 42}}, {2, {7, 42}}])) == []
    end

    test "prune keeps only the scene's keys" do
      sent = MapSet.new([{1, {7, 42}}, {1, {7, 41}}, {3, {1, 0}}])
      assert Images.prune(sent, scene([{1, [g()]}])) == MapSet.new([{1, {7, 42}}])
    end

    test "withheld is the placement's payload without data" do
      assert Images.withheld(g()) == %{@img | data: nil}
    end
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

    Store.reset()
  end

  # a frozen conn keeps what it writes (newest first): no socket needed
  defp conn, do: %Remote{socket: :none, frozen: true}
  defp written(state), do: Enum.reverse(state.frozen_out)

  describe "Out.write" do
    setup do
      reset()
      on_exit(&reset/0)
      on_exit(fn -> Application.delete_env(:herdr_server, :remote_image_max_bytes) end)

      # an attached client opens pane 1
      info = %{kind: :term, transport: :ref, size: %{cols: 80, rows: 24}, cell_px: nil}

      {:ok, _, _} =
        GenServer.call(
          Protocol.endpoint(),
          {:attach, Map.merge(info, %{caps: %{}, client: self()})}
        )

      assert_receive {:scene, _}, 500
      {:ok, %{vt: vt}} = Fake.Keeper.lookup(Rows.kernel_id(1))
      :ok = Fake.Vt.set_graphics(vt, [g()], %{7 => @img})
      :ok
    end

    test "an unsent image goes before its scene, once; gone and back resends it" do
      s = scene([{1, [g()]}])
      state = Out.write(conn(), {:scene, s})
      assert written(state) == [{:image, 1, {7, 42}, @img}, {:scene, s}]

      state = Out.write(state, {:scene, s})
      assert Enum.drop(written(state), 2) == [{:scene, s}]

      empty = scene([{1, []}])
      state = state |> Out.write({:scene, empty}) |> Out.write({:scene, s})

      assert Enum.drop(written(state), 4) == [{:image, 1, {7, 42}, @img}, {:scene, s}]
    end

    test "above the cap the payload is withheld" do
      Application.put_env(:herdr_server, :remote_image_max_bytes, 4)
      s = scene([{1, [g()]}])

      assert written(Out.write(conn(), {:scene, s})) == [
               {:image, 1, {7, 42}, %{@img | data: nil}},
               {:scene, s}
             ]
    end

    test "an image the vt no longer has is skipped and not marked sent" do
      s = scene([{1, [g(%{image: {8, 1}})]}])
      state = Out.write(conn(), {:scene, s})
      assert written(state) == [{:scene, s}]
      assert state.images_sent == MapSet.new()
    end

    test "full/1 (a resume) resends the scene's images" do
      s = scene([{1, [g()]}])
      state = Out.put(%{conn() | frozen: false, socket: nil}, {:scene, s})
      state = %{state | images_sent: MapSet.new([{1, {7, 42}}]), socket: :none, frozen: true}
      assert [{:image, 1, {7, 42}, @img}, {:scene, _}] = written(Out.full(state))
    end
  end
end
