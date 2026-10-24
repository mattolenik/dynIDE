defmodule HerdrIntegration.SecondClientTest do
  @moduledoc """
  Scripted stand-in for the manual second-client exit check: two clients at
  different sizes attached to one session see each other's typing.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver

  setup do
    Driver.reset()
  end

  test "a second client at another size sees the same session" do
    a = Driver.start_client({120, 40})
    b = Driver.start_client({80, 24})

    Driver.type(a, "abc")
    assert Driver.wait_screen(a, &in_pane?(a, &1, "abc"))
    assert Driver.wait_screen(b, &in_pane?(b, &1, "abc"))

    Driver.type(b, "xyz")
    assert Driver.wait_screen(a, &in_pane?(a, &1, "abcxyz"))
    assert Driver.wait_screen(b, &in_pane?(b, &1, "abcxyz"))

    sa = Driver.scene(a)
    sb = Driver.scene(b)
    assert sa.size == %{cols: 120, rows: 40}
    assert sb.size == %{cols: 80, rows: 24}
    assert Enum.map(sa.panes, & &1.id) == Enum.map(sb.panes, & &1.id)
  end

  defp in_pane?(client, screen, text) do
    Enum.any?(
      Driver.scene(client).panes,
      &(&1.rect |> Driver.region(screen) |> Enum.join() =~ text)
    )
  end
end
