defmodule HerdrIntegration.InlineClientTest do
  @moduledoc """
  An inline-transport client (rows travel in scenes and `{:rows, ...}`) shows
  the same pane contents as a ref client, clipped to its own rects: at another
  size, at the driver's size, after typing and after a split.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver

  setup do
    Driver.reset()
  end

  test "an inline client matches the ref client's pane contents" do
    ref = Driver.start_client({120, 40})
    inline = Driver.start_client({80, 24}, transport: :inline)

    Driver.type(ref, "abc")
    assert Driver.wait_screen(inline, &(&1 |> Enum.join() =~ "abc"))
    assert same_panes?(ref, inline)

    # attaching at the driver's size: the first scene brings the rows
    same = Driver.start_client({120, 40}, transport: :inline)
    assert same_panes?(ref, same)

    # split: the new pane's rows arrive with the scene that contains it
    Driver.type(ref, "\x02v")
    for c <- [ref, inline, same], do: assert(wait_panes(c, 2))
    Driver.type(ref, "xyz")
    assert Driver.wait_screen(inline, &(&1 |> Enum.join() =~ "xyz"))

    for c <- [inline, same], do: assert(same_panes?(ref, c))
  end

  defp wait_panes(client, n),
    do: Driver.wait_screen(client, fn _ -> length(Driver.scene(client).panes) == n end)

  # every pane's content, clipped to the smaller of the two rects, is equal (re-checked
  # after each frame of `b`, for up to a second)
  defp same_panes?(a, b), do: Driver.wait_screen(b, fn _ -> diff(a, b) == [] end) or diff(a, b)

  defp diff(a, b) do
    sa = Driver.scene(a)
    sb = Driver.scene(b)
    {screen_a, screen_b} = {Driver.screen(a), Driver.screen(b)}

    for %{id: id, rect: ra} <- sa.panes,
        %{rect: rb} <- Enum.filter(sb.panes, &(&1.id == id)),
        w = min(ra.w, rb.w),
        h = min(ra.h, rb.h),
        left = Driver.region(%{ra | w: w, h: h}, screen_a),
        right = Driver.region(%{rb | w: w, h: h}, screen_b),
        left != right,
        do: {id, left, right}
  end
end
