defmodule HerdrIntegration.StatusLineTest do
  # The runtime status nodes from View reach the terminal client's status row through
  # Compose unchanged (role :text), next to a long notice; tabs have their own row.
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrServer.App.Actions
  alias HerdrServer.Client.{Keys, State}
  alias HerdrServer.{RuntimeStatus, View}
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme

  # prefix + c, as a client would
  defp new_tab(app) do
    {_, {:run, {m, f, a}}} =
      Keys.resolve(%{mode: :prefix, swallow: MapSet.new()}, app.ui.keybinds, Event.key("c"))

    elem(Kernel.apply(m, f, [app | a]), 0)
  end

  defp status_row(app, client), do: app |> screen(client) |> List.last()

  defp screen(app, client) do
    scene = View.compute(app, client)
    rows = Map.new(scene.panes, &{&1.id, {}})
    scene |> Compose.frame(rows, Theme.default()) |> Enum.map(&Cells.to_text(elem(&1, 1)))
  end

  test "reload, tests and handoff render on the status row; the hint stays" do
    rt =
      Enum.reduce(
        [
          {:herdr_reload, {:loaded, 3, [A, B]}},
          {:herdr_reload, {:tests, :failed, %{files: 2, failures: 1, ms: 40}}},
          {:handoff, %{phase: :adopted, gen: 2, panes: [1], kind: :graceful}}
        ],
        RuntimeStatus.new(),
        &RuntimeStatus.apply(&2, &1, 0)
      )

    {app, _} = Actions.init(%{cols: 80, rows: 24})
    client = %State{size: %{cols: 80, rows: 24}, transport: :ref, mode: :terminal, runtime: rt}
    notice = %{level: :warning, text: String.duplicate("w", 200), ref: nil}

    text = status_row(app, %{client | notice: notice})
    assert String.length(text) == 80
    assert text =~ "r3 2m tests 1 failed handoff graceful g2 w"
    assert String.ends_with?(text, "ctrl+b")

    # 6 tabs go on the tab bar row, not the status row
    tabs = Enum.reduce(1..5, app, fn _, a -> new_tab(a) end)
    [top | _] = rows = screen(tabs, %{client | notice: notice})
    assert top =~ " 5:5   6:6 "
    assert List.last(rows) == text

    # 50 cols: handoff dropped, reload and tests kept, notice clipped, hint intact
    text = status_row(tabs, %{client | notice: notice, size: %{cols: 50, rows: 24}})
    assert String.length(text) == 50
    assert text =~ ~r/^TERMINAL r3 2m tests 1 failed w+ ctrl\+b$/
    refute text =~ "handoff"
  end
end
