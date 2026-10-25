defmodule HerdrTerm.Client.Term.RenderGraphicsReloadTest do
  # "A reload must not leave ghost images": Render.Graphics hot-swapped under a running
  # Render (simulated: the module recompiled from its source with Code.compile_string,
  # not through the Watcher), the fake blit's op stream folded into a model of the host.
  # async: false, the swapped module is global.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.Fixture
  alias HerdrTerm.Client
  alias HerdrTerm.Client.Term.Render.Graphics
  alias HerdrTerm.Kernel.Fake.{Blit, Tty}
  alias HerdrTerm.Test.FakeServer

  @wait 2_000

  def rows(_id), do: nil

  def image(_pane, _image_id),
    do: %{format: :rgba, width: 100, height: 100, bytes: 6, data: "pixels"}

  setup do
    {:module, _} = Code.ensure_loaded(Graphics)
    source = Graphics.module_info(:compile)[:source] |> to_string()
    original = File.read!(source)
    Code.put_compiler_option(:ignore_module_conflict, true)

    on_exit(fn ->
      swap(original, source)
      Code.put_compiler_option(:ignore_module_conflict, false)
    end)

    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []}, %{images: {__MODULE__, :image, []}})
    sup = start_supervised!({Client, endpoint: ep}, id: ep)
    assert_receive {:attached, _, _session}, @wait
    tty = Client.tty(sup)
    Tty.set_size(tty, {80, 24, 800, 480})
    Blit.subscribe_frames(tty, self())
    %{render: Client.render(sup), source: source, original: original}
  end

  defp swap(code, source) do
    Code.compile_string(code, source)
    :ok
  end

  defp graphic(placement, x) do
    %{
      image: {7, 42},
      placement: placement,
      x: x,
      y: 0,
      cols: 10,
      rows: 5,
      x_off: 0,
      y_off: 0,
      src: {0, 0, 0, 0},
      px: {0, 0},
      z: 0,
      size: {100, 100},
      format: :rgba,
      bytes: 6
    }
  end

  defp scene(graphics) do
    sc = Fixture.load("single_pane_80x24")
    %{sc | panes: Enum.map(sc.panes, &%{&1 | graphics: graphics})}
  end

  # the host after `ops`: images and placements it holds
  defp host(ops, host \\ %{images: MapSet.new(), placements: MapSet.new()}) do
    Enum.reduce(ops, host, fn
      :delete_all, _ -> %{images: MapSet.new(), placements: MapSet.new()}
      {:upload, %{id: id}}, h -> %{h | images: MapSet.put(h.images, id)}
      {:place, %{id: id, placement: p}}, h -> %{h | placements: MapSet.put(h.placements, {id, p})}
      {:delete_placement, id, p}, h -> %{h | placements: MapSet.delete(h.placements, {id, p})}
      {:delete_image, id}, h -> drop_image(h, id)
    end)
  end

  defp drop_image(h, id) do
    %{
      images: MapSet.delete(h.images, id),
      placements: MapSet.reject(h.placements, &(elem(&1, 0) == id))
    }
  end

  # the next frame's ops folded into `h`; nothing on the host but what this frame placed
  defp frame(h) do
    assert_receive {:frame, _, %{graphics: ops}}, @wait
    h = host(ops, h)
    placed = for {:place, %{id: id, placement: p}} <- ops, into: MapSet.new(), do: {id, p}
    assert h.placements == placed, "stale placements: #{inspect(ops)}"
    assert h.images == MapSet.new(placed, &elem(&1, 0)), "stale images: #{inspect(ops)}"
    {ops, h}
  end

  defp frame_until(h, n \\ 20) do
    {ops, h} = frame(h)

    cond do
      Enum.any?(ops, &match?({:upload, _}, &1)) -> {ops, h}
      n == 0 -> flunk("no upload")
      true -> frame_until(h, n - 1)
    end
  end

  defp places(ops), do: for({:place, _} = op <- ops, do: op)

  test "a Graphics edit without empty/0 or file_transport?/1 crashes neither a running nor a starting Render",
       ctx do
    broken =
      ctx.original
      |> String.replace("  @spec empty() :: cache\n", "")
      |> String.replace("  def empty, do: %{images: %{}, placements: MapSet.new()}\n", "")
      |> String.replace(~r/  @spec file_transport\?.*\n  def file_transport\?\(env\),\n.*\n/, "")

    swap(broken, ctx.source)
    refute function_exported?(Graphics, :empty, 0)
    refute function_exported?(Graphics, :file_transport?, 1)

    # running: the frame path never calls Graphics outside the Guard
    send(ctx.render, {:scene, scene([graphic(1, 0)])})
    {ops, _} = frame(host([]))
    assert [:delete_all, {:upload, _}, {:place, _}] = ops
    send(ctx.render, :repaint)
    assert {[:delete_all | _], _} = frame(host([]))
    assert Process.alive?(ctx.render)

    # starting: init/1 falls back to direct transport
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []}, %{images: {__MODULE__, :image, []}})
    sup = start_supervised!({Client, endpoint: ep}, id: ep)
    assert_receive {:attached, _, _}, @wait
    assert %{kitty: %{file?: false}} = :sys.get_state(Client.render(sup))
  end

  test "a good reload replays the same placements; a failing pass clears and re-uploads; no ghost after the pane goes",
       ctx do
    %{render: render} = ctx
    two = scene([graphic(1, 0), graphic(2, 20)])
    send(render, {:scene, two})
    {ops, h} = frame(host([]))
    assert [:delete_all, {:upload, _} | _] = ops
    assert length(places(ops)) == 2

    # good reload: a new version of the module (one more function), same placements
    swap(
      String.replace(ctx.original, "  def empty,", "  def reload_marker, do: 1\n\n  def empty,"),
      ctx.source
    )

    assert function_exported?(Graphics, :reload_marker, 0)
    send(render, {:scene, two})
    {after_reload, h} = frame(h)
    assert after_reload == places(ops)

    # bad edit: run/4 raises; the guarded pass fails and the host is cleared
    bad =
      String.replace(
        ctx.original,
        "  def run(frame, scene, chrome, ctx) do\n",
        "  def run(frame, scene, chrome, ctx) do\n    if frame != :never, do: raise(\"ghost test bad edit\")\n"
      )

    swap(bad, ctx.source)
    send(render, {:scene, two})
    {failed, h} = frame(h)
    assert failed == [:delete_all]
    assert h.images == MapSet.new()

    # fixed (the original back): the retry re-uploads and places the same ids
    swap(ctx.original, ctx.source)
    {recovered, h} = frame_until(h)
    assert [{:upload, _} | _] = recovered
    assert places(recovered) == places(ops)

    # the scene drops the pane: every host image deleted
    send(render, {:scene, %{two | panes: []}})
    {_, h} = frame(h)
    assert h == host([])
  end
end
