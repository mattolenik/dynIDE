defmodule HerdrIntegration.SecondClientTest do
  @moduledoc """
  Scripted stand-in for the manual second-client exit check: two clients at
  different sizes attached to one session see each other's typing.
  """
  use ExUnit.Case, async: false

  alias HerdrIntegration.Driver
  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Store
  alias HerdrTerm.Client

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

  test "prefix mode is per client: B types on the fast path while A is in prefix mode" do
    a = Driver.start_client({80, 24})
    b = Driver.start_client({80, 24})
    [pane] = Enum.map(Driver.scene(a).panes, & &1.id)
    input_a = Client.input(a)
    input_b = Client.input(b)

    Driver.type(a, "\x02")
    assert wait(fn -> :sys.get_state(input_a).mode == :prefix end)
    assert wait(fn -> mode(a) == "PREFIX" end)

    seq_b = :sys.get_state(input_b).seq
    Driver.type(b, "x")
    assert Driver.wait_screen(b, &in_pane?(b, &1, "x"))
    # fast path: B's input sent nothing to its session
    assert :sys.get_state(input_b).seq == seq_b
    assert Enum.map(Driver.scene(b).panes, & &1.id) == [pane]
    assert mode(b) == "TERMINAL"
    assert mode(a) == "PREFIX"

    Driver.type(a, "x")
    assert wait(fn -> mode(a) == "TERMINAL" and Driver.scene(a).panes != [] end)
    assert wait(fn -> Enum.map(Driver.scene(a).panes, & &1.id) == [pane + 1] end)
    assert :sys.get_state(input_a).mode == :terminal
    assert Map.keys(Store.snapshot().session.panes) == [pane + 1]
  end

  defp mode(client),
    do: Node.find(Driver.scene(client).chrome, [:status, :mode]).text

  defp wait(fun, n \\ 100) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && wait(fun, n - 1)
    end
  end

  defp in_pane?(client, screen, text) do
    Enum.any?(
      Driver.scene(client).panes,
      &(&1.rect |> Driver.region(screen) |> Enum.join() =~ text)
    )
  end
end
