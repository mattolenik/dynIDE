defmodule DynideServer.View.WindowTitleTest do
  use ExUnit.Case, async: true

  import DynideServer.ViewHelpers

  alias DynideServer.Client.State
  alias DynideServer.View
  alias DynideServer.View.WindowTitle

  defp app, do: fresh(80, 24)

  test "tokens" do
    a = app()
    ws = hd(a.session.workspaces)
    tab = hd(ws.tabs)
    assert WindowTitle.render("{hostname}: {workspace}", a, nil, "box") == "box: #{ws.name}"

    assert WindowTitle.render("{tab}|{terminal_title}|{x}", a, "vim", nil) ==
             "#{tab.name}|vim|{x}"

    assert WindowTitle.render("{workspace}", a, nil) == ws.name
  end

  test "controls are stripped, length capped, empty is nil" do
    assert WindowTitle.render("a\e]0;b\ac\u0085", app(), nil, nil) == "a]0;bc"

    assert WindowTitle.render(String.duplicate("x", 300), app(), nil, nil) |> String.length() ==
             200

    assert WindowTitle.render("", app(), nil, nil) == nil
    assert WindowTitle.render("{terminal_title}", app(), nil, nil) == nil
  end

  test "the {pane} token and invalid utf-8 in a terminal title" do
    a = put_in(app().session.panes[1][:name], "logs")
    assert WindowTitle.render("{pane}", a, nil, nil) == "logs"
    assert WindowTitle.render("{terminal_title}", a, <<"ab", 0xFF, "c">>, nil) == "ab\uFFFDc"
  end

  test "the root prop: template, override wins" do
    c = %State{size: %{cols: 80, rows: 24}, transport: :ref, hostname: "box"}
    ws = hd(app().session.workspaces)
    assert View.compute(app(), c).chrome.props.window_title == "box: #{ws.name}"
    assert View.compute(app(), %{c | window_title: "mine\a"}).chrome.props.window_title == "mine"
    # an override that cleans to empty falls back to the template
    assert View.compute(app(), %{c | window_title: "\a"}).chrome.props.window_title ==
             "box: #{ws.name}"
  end
end
