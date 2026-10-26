defmodule DynideIntegration.FifteenPanesTest do
  @moduledoc """
  Scripted stand-in for the manual 15-pane exit check: one 200x50 client,
  15 panes made with prefix splits, output floods into 5 panes (the
  htop/cat stand-in) while typing into another. Every frame stays a full,
  untorn 200x50 grid, each flooded pane shows its last line, and the screen
  converges to the final scene composed with the server's rows.
  """
  use ExUnit.Case, async: false

  alias DynideIntegration.Driver

  # Exactly 2,000,000 bytes in total: 400,000 per flooded pane, 6666
  # numbered 60-byte lines then a 40-byte `END-<id>` marker line.
  @per_pane 400_000
  @lines 6666

  setup do
    Driver.reset()
  end

  test "15 panes, 2,000,000 bytes flooded into 5, typing in another" do
    client = Driver.start_client({200, 50})
    frames = Driver.trace_frames(client)

    scene = Driver.grow(client, 15)
    assert length(scene.panes) == 15

    [typed | others] = Enum.map(scene.panes, & &1.id)
    flooded = Enum.take(others, 5)
    Driver.click(client, typed)

    floods = Map.new(flooded, &{&1, flood(&1)})
    assert floods |> Map.values() |> Enum.map(&IO.iodata_length/1) |> Enum.sum() == 2_000_000

    :ok = Driver.reset_frames(frames)

    task =
      Task.async(fn ->
        floods
        |> Enum.map(fn {id, chunks} -> Enum.map(chunks, &{id, &1}) end)
        |> Enum.zip_with(& &1)
        |> Enum.each(&Enum.each(&1, fn {id, chunk} -> Driver.output(id, chunk) end))
      end)

    Driver.type(client, "hello")
    assert Driver.wait_screen(client, &shows?(scene, typed, &1, "hello"), 2000)
    Task.await(task, 10_000)

    for id <- flooded do
      assert Driver.wait_screen(client, &shows?(scene, id, &1, "END-#{id} "), 2000),
             "pane #{id} never showed its last line"
    end

    assert %{count: n, bad: []} = Driver.frame_stats(frames)
    assert n > 0

    Driver.wait_screen(client, &(&1 == Driver.expected_screen(client)), 2000)
    assert Driver.screen(client) == Driver.expected_screen(client)
  end

  # chunks of 100 numbered lines, then the marker line
  defp flood(id) do
    lines = for n <- 1..@lines, do: String.pad_trailing("#{id}:#{n} ", 58, "x") <> "\r\n"
    marker = String.pad_trailing("END-#{id}", 38) <> "\r\n"
    chunks = lines |> Enum.chunk_every(100) |> Enum.map(&IO.iodata_to_binary/1)
    chunks = chunks ++ [marker]
    @per_pane = IO.iodata_length(chunks)
    chunks
  end

  defp shows?(scene, id, screen, text) do
    rect = Enum.find(scene.panes, &(&1.id == id)).rect
    rect |> Driver.region(screen) |> Enum.join() =~ text
  end
end
