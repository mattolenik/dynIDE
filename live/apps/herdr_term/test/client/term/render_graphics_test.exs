defmodule HerdrTerm.Client.Term.RenderGraphicsTest do
  # the kitty placement pass through Render and the fake blit; one test flips app env
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.Fixture
  alias HerdrTerm.Client
  alias HerdrTerm.Kernel.Fake.{Blit, Tty}
  alias HerdrTerm.Test.FakeServer

  @wait 2_000
  @key {1, 7, 42}

  def rows(_id), do: nil

  def image(pane, image_id, test, data) do
    send(test, {:image_fetched, pane, image_id})
    data = if is_pid(data), do: Agent.get(data, & &1), else: data
    if data == :boom, do: raise("images boom")
    %{format: :rgba, width: 100, height: 100, bytes: 6, data: data}
  end

  defp start(data \\ "pixels") do
    ep = FakeServer.unique_name()

    FakeServer.start(self(), ep, {__MODULE__, :rows, []}, %{
      images: {__MODULE__, :image, [self(), data]}
    })

    sup = start_supervised!({Client, endpoint: ep}, id: ep)
    assert_receive {:attached, _, _session}, @wait
    tty = Client.tty(sup)
    Tty.set_size(tty, {80, 24, 800, 480})
    Blit.subscribe_frames(tty, self())
    %{render: Client.render(sup), tty: tty}
  end

  defp graphic(over \\ []) do
    Map.merge(
      %{
        image: {7, 42},
        placement: 1,
        x: 0,
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
      },
      Map.new(over)
    )
  end

  defp scene(graphics) do
    sc = Fixture.load("single_pane_80x24")
    %{sc | panes: Enum.map(sc.panes, &%{&1 | graphics: graphics})}
  end

  defp frame_ops do
    assert_receive {:frame, _, %{graphics: ops}}, @wait
    ops
  end

  # frames until one has an upload (frames in between may carry no ops)
  defp until_upload(n \\ 20) do
    ops = frame_ops()

    cond do
      Enum.any?(ops, &match?({:upload, _}, &1)) -> ops
      n == 0 -> flunk("no upload")
      true -> until_upload(n - 1)
    end
  end

  test "first frame clears the host, uploads then places; later frames only place" do
    %{render: render} = start()
    send(render, {:scene, scene([graphic()])})

    assert [:delete_all, {:upload, %{id: id, data: "pixels"}}, {:place, %{id: id, x: 26, y: 1}}] =
             frame_ops()

    assert_received {:image_fetched, 1, 7}
    send(render, {:scene, scene([graphic(x: 1)])})
    assert [{:place, %{id: ^id, x: 27}}] = frame_ops()
    refute_received {:image_fetched, _, _}

    # the placement gone: placement and image deleted on the host
    send(render, {:scene, scene([])})
    assert [{:delete_placement, ^id, _}, {:delete_image, ^id}] = frame_ops()
    send(render, :repaint)
    assert [] = frame_ops()
  end

  test "a failing graphics pass sends :delete_all and the cell frame still goes out" do
    %{render: render, tty: tty} = start()
    send(render, {:scene, scene([graphic(cols: :bad)])})
    assert_receive {:frame, _, %{graphics: [:delete_all], rows: rows}}, @wait
    assert length(rows) == 24
    assert Enum.at(Blit.screen(tty), 0) != ""

    # skipped for the retry window: no re-run, no second :delete_all
    send(render, {:scene, scene([graphic(cols: :bad)])})
    assert [] = frame_ops()

    # the cache was reset: a good scene uploads again once the window is over
    send(render, {:scene, scene([graphic()])})
    assert [{:upload, _}, {:place, _}] = until_upload()
  end

  test "a failing image fetch is retried after the retry window" do
    agent = start_supervised!({Agent, fn -> :boom end})
    %{render: render} = start(agent)
    send(render, {:scene, scene([graphic()])})
    assert [:delete_all] = frame_ops()
    assert_received {:image_fetched, 1, 7}
    Agent.update(agent, fn _ -> "pixels" end)
    # no new scene or damage: the retry timer brings the frame
    assert [{:upload, %{data: "pixels"}}, {:place, _}] = until_upload()
  end

  test "the pane removed from the scene: placement and image deleted, image pruned" do
    %{render: render} = start()
    send(render, {:scene, scene([graphic()])})
    assert [:delete_all, {:upload, %{id: id}}, {:place, _}] = frame_ops()
    send(render, {:scene, %{scene([]) | panes: []}})
    assert [{:delete_placement, ^id, _}, {:delete_image, ^id}] = frame_ops()
    assert :sys.get_state(render).images == %{}
  end

  test "an inline {:image} is used without a fetch" do
    %{render: render} = start()
    payload = %{format: :rgb, width: 2, height: 1, bytes: 6, data: "inline"}
    send(render, {:image, 1, {7, 42}, payload})
    send(render, {:scene, scene([graphic()])})
    assert [:delete_all, {:upload, %{data: "inline", format: :rgb}}, {:place, _}] = frame_ops()
    refute_received {:image_fetched, _, _}
    assert %{@key => ^payload} = :sys.get_state(render).images
  end

  test "a withheld image draws a label, no upload" do
    %{render: render, tty: tty} = start(nil)
    send(render, {:scene, scene([graphic(cols: 20)])})
    assert [:delete_all] = frame_ops()
    assert Enum.at(Blit.screen(tty), 1) =~ "[image 100x100]"
  end

  test "unknown cell px: no placements" do
    %{render: render, tty: tty} = start()
    Tty.set_size(tty, {80, 24, 0, 0})
    send(render, {:scene, scene([graphic()])})
    assert [:delete_all] = frame_ops()
    refute_received {:image_fetched, _, _}
  end

  test "kitty_graphics false: no graphics ops at all" do
    Application.put_env(:herdr_term, :kitty_graphics, false)
    on_exit(fn -> Application.delete_env(:herdr_term, :kitty_graphics) end)
    %{render: render} = start()
    send(render, {:scene, scene([graphic()])})
    assert [] = frame_ops()
    refute_received {:image_fetched, _, _}
  end
end
