defmodule HerdrServer.Client.ToastsTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Client.Toasts
  alias HerdrServer.ViewHelpers

  defp alert(pane, level \\ :attention, sound \\ :request),
    do: %{kind: :notification, level: level, title: "pi", body: "1 · 1", pane: pane, sound: sound}

  # pane 1 in tab 1 (background), pane 2 in the active tab 2
  defp app, do: ViewHelpers.fresh(80, 24) |> ViewHelpers.new_tab()

  test "a background pane's alert is forwarded whole and queued as a toast" do
    a = alert(1)

    assert {^a, [%{id: 7, level: :attention, title: "pi", body: "1 · 1", pane: 1}]} =
             Toasts.alert([], a, app(), nil, 7)
  end

  test "the active tab suppresses the toast and the done sound unless the terminal is unfocused" do
    for focused <- [nil, true] do
      # the request sound is never suppressed: forwarded as sound only
      assert {%{title: nil, body: nil, sound: :request}, []} =
               Toasts.alert([], alert(2), app(), focused, 1)

      assert {nil, []} = Toasts.alert([], alert(2, :done, :done), app(), focused, 1)
    end

    assert {%{title: "pi", sound: :done}, [%{id: 1}]} =
             Toasts.alert([], alert(2, :done, :done), app(), false, 1)
  end

  test "only herdr delivery queues toasts; the alert still goes to the client" do
    for d <- [:off, :terminal, :system] do
      app = put_in(app().ui.toast.delivery, d)
      assert {%{title: "pi"}, []} = Toasts.alert([], alert(1), app, nil, 1)
    end
  end

  test "the queue keeps the newest 8; drop takes one out" do
    toasts =
      Enum.reduce(1..10, [], fn i, t -> elem(Toasts.alert(t, alert(1), app(), nil, i), 1) end)

    assert Enum.map(toasts, & &1.id) == Enum.to_list(10..3//-1)
    assert {%{id: 5, pane: 1}, rest} = Toasts.drop(toasts, 5)
    assert length(rest) == 7
    assert {nil, ^rest} = Toasts.drop(rest, 5)
  end

  test "ttl: 8 s attention, 5 s otherwise; options override per level" do
    assert Toasts.ttl(:attention) == 8000
    assert Toasts.ttl(:done) == 5000
    assert Toasts.ttl(:info) == 5000
    assert Toasts.ttl(:attention, done: 10) == 8000
    assert Toasts.ttl(:info, done: 10) == 10
  end
end
