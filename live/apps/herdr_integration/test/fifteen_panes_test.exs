defmodule HerdrIntegration.FifteenPanesTest do
  @moduledoc """
  Scripted stand-in for the manual 15-pane exit check: one 200x50 client,
  15 panes made with prefix splits, output floods into 5 panes (the
  htop/cat stand-in) while typing into another. Every frame stays a full,
  untorn 200x50 grid and the final screen has no stale cells.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver

  @flood_bytes 2_000_000

  setup do
    Driver.reset()
  end

  test "15 panes, floods in 5, typing in another" do
    client = Driver.start_client({200, 50})
    frames = Driver.trace_frames(client)

    scene = Driver.grow(client, 15)
    assert length(scene.panes) == 15

    [typed | others] = Enum.map(scene.panes, & &1.id)
    flooded = Enum.take(others, 5)
    Driver.click(client, typed)

    line = String.duplicate("x", 60) <> "\r\n"
    chunk = String.duplicate(line, 100)
    per_pane = div(@flood_bytes, 5 * byte_size(chunk))

    flood =
      Task.async(fn ->
        for _ <- 1..per_pane, id <- flooded, do: Driver.output(id, chunk)
      end)

    Driver.type(client, "hello")
    rect = Enum.find(scene.panes, &(&1.id == typed)).rect

    assert Driver.wait_screen(
             client,
             &(rect |> Driver.region(&1) |> Enum.join() =~ "hello"),
             2000
           )

    Task.await(flood, 10_000)
    assert Driver.quiesce(client) == :ok

    assert %{count: n, bad: []} = Driver.frame_stats(frames)
    assert n > 0
    assert Driver.screen(client) == Driver.expected_screen(client)
  end
end
