defmodule HerdrIntegration.KeystrokeCostTest do
  @moduledoc """
  Per-keystroke render cost does not grow with the pane count: one keystroke
  into a 15-pane client produces exactly one frame and one row fetch (the
  typed pane), and the frame's cursor sits after the typed character.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver

  setup do
    Driver.reset()
  end

  test "one keystroke into a 15-pane client: one frame, one fetch, cursor right" do
    client = Driver.start_client({200, 50})
    tracer = Driver.trace_frames(client)
    scene = Driver.grow(client, 15)
    [typed | _] = scene.panes
    Driver.click(client, typed.id)
    assert Driver.wait_screen(client, fn _ -> Driver.scene(client).focus.pane == typed.id end)
    :ok = Driver.quiesce(client)
    :ok = Driver.reset_frames(tracer)

    Driver.type(client, "k")
    assert Driver.wait_screen(client, &(typed.rect |> Driver.region(&1) |> hd() =~ ~r/^k/))
    :ok = Driver.quiesce(client)

    assert %{count: 1, bad: [], fetches: [id]} = Driver.frame_stats(tracer)
    assert id == typed.id
    assert Driver.cursor(client) == {typed.rect.x + 1, typed.rect.y}
  end
end
