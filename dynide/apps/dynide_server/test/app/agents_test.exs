defmodule DynideServer.App.AgentsTest do
  use ExUnit.Case, async: true

  alias DynideServer.App.{Actions, Agents, Commands}

  # pane 1 in the active tab, pane 2 in a background tab
  defp app do
    {app, _} = Commands.create_tab(elem(Actions.init(%{cols: 80, rows: 24}), 0), 1, nil, false)
    app
  end

  defp state(app, id), do: app.session.panes[id][:agent_state]

  test "idle after work is done in a background tab and idle in the active tab" do
    a = app()
    assert Agents.status(a, 2, :working, :idle) == :done
    assert Agents.status(a, 2, :blocked, :idle) == :done
    assert Agents.status(a, 2, :done, :idle) == :done
    assert Agents.status(a, 1, :working, :idle) == :idle
    assert Agents.status(a, 2, nil, :idle) == :idle
    assert Agents.status(a, 2, :unknown, :idle) == :idle
    assert Agents.status(a, 2, :done, :working) == :working
  end

  test "seen turns done into idle only in the active tab" do
    a = app()
    a = put_in(a.session.panes[2][:agent_state], :done)
    assert a |> Agents.seen() |> state(2) == :done

    {b, _} = Commands.focus_tab(a, 1, 2)
    assert b |> Agents.seen() |> state(2) == :idle
  end
end
