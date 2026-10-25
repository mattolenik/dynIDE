ExUnit.start()

defmodule HerdrServer.ViewHelpers do
  @moduledoc false
  alias HerdrScene.Event
  alias HerdrServer.App.Actions
  alias HerdrServer.Client.Keys
  alias HerdrServer.Layout

  def fresh(c, r), do: elem(Actions.init(%{cols: c, rows: r}), 0)

  @doc "Prefix + `key` as a client would: resolved by `Client.Keys`, the action applied."
  def pfx(app, key) do
    input = %{mode: :prefix, swallow: MapSet.new()}

    case Keys.resolve(input, app.ui.keybinds, Event.key(key)) do
      {_, {:run, {m, f, a}}} -> elem(Kernel.apply(m, f, [app | a]), 0)
      {_, _} -> app
    end
  end

  @doc "Opens a tab without the new-tab name prompt."
  def new_tab(app), do: elem(Actions.new_tab(app), 0)

  @doc "Grows to `n` panes by splitting the largest pane each time, alternating direction."
  def many(app, n) do
    Enum.reduce(1..(n - 1)//1, app, fn i, a ->
      big = layout(a) |> Layout.panes(a.session.area) |> Enum.max_by(&(&1.rect.w * &1.rect.h))
      pfx(focus(a, big.id), if(rem(i, 2) == 1, do: "v", else: "-"))
    end)
  end

  defp layout(app), do: tab(app).layout

  defp tab(app) do
    ws = hd(app.session.workspaces)
    Enum.find(ws.tabs, &(&1.id == ws.active_tab))
  end

  # focuses a pane through App.Actions with a left press inside its content rect
  defp focus(app, id) do
    area = app.session.area

    %{rect: r} =
      layout(app)
      |> Layout.rects(area, Layout.opts(tab(app), app.ui))
      |> Enum.find(&(&1.id == id))

    ev = {:mouse, %{kind: :press, button: :left, x: r.x, y: r.y, mods: [], px: nil}}
    elem(Actions.apply(app, ev), 0)
  end

  @doc "Adds a workspace named `name` with one tab and one pane and makes it active."
  def add_workspace(app, name) do
    id = app.session.next_id
    ws_id = Enum.max_by(app.session.workspaces, & &1.id).id + 1

    ws = %{
      id: ws_id,
      name: name,
      tabs: [%{id: 1, name: "1", layout: Layout.new(id)}],
      active_tab: 1
    }

    app
    |> update_in([:session], fn s ->
      %{
        s
        | workspaces: s.workspaces ++ [ws],
          active_workspace: ws_id,
          next_id: id + 1,
          panes: Map.put(s.panes, id, %{title: nil, layout_gen: 0})
      }
    end)
    |> put_in([:focus, Access.key(:pane)], id)
  end

  @doc "The input mode a client is in after pressing prefix, then `keys`."
  def mode_after(app, keys) do
    Enum.reduce(keys, %{mode: :prefix, swallow: MapSet.new()}, fn k, st ->
      elem(Keys.resolve(st, app.ui.keybinds, Event.key(k)), 0)
    end).mode
  end
end
