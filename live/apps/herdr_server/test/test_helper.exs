ExUnit.start()

defmodule HerdrServer.ViewHelpers do
  @moduledoc false
  alias HerdrScene.Event
  alias HerdrServer.App.Actions
  alias HerdrServer.Layout

  def fresh(c, r), do: elem(Actions.init(%{cols: c, rows: r}), 0)

  def keys(app, ks) do
    Enum.reduce(ks, app, fn k, a ->
      {key, mods} = if is_tuple(k), do: k, else: {k, []}
      elem(Actions.apply(a, Event.key(key, mods)), 0)
    end)
  end

  def pfx(app, key), do: keys(app, [{"b", [:ctrl]}, key])

  @doc "Grows to `n` panes by splitting the largest pane each time, alternating direction."
  def many(app, n) do
    Enum.reduce(1..(n - 1)//1, app, fn i, a ->
      big = layout(a) |> Layout.panes(a.session.area) |> Enum.max_by(&(&1.rect.w * &1.rect.h))
      pfx(focus(a, big.id), if(rem(i, 2) == 1, do: "v", else: "-"))
    end)
  end

  defp layout(app) do
    ws = hd(app.session.workspaces)
    Enum.find(ws.tabs, &(&1.id == ws.active_tab)).layout
  end

  defp focus(app, id) do
    ws = hd(app.session.workspaces)
    l = Layout.focus(layout(app), id)
    tabs = Enum.map(ws.tabs, &if(&1.id == ws.active_tab, do: %{&1 | layout: l}, else: &1))
    app = put_in(app.session.workspaces, [%{ws | tabs: tabs}])
    put_in(app.focus.pane, id)
  end
end
