defmodule HerdrServer.View.Tabs do
  @moduledoc """
  The tab bar region: one `:tab` per tab of the workspace (`props: %{index, active,
  zoomed}`, 1-based index; `zoomed` on the active tab while its zoom holds) and a trailing
  `:button` `:new_tab`. Pure.

  `drag` is the client's `Client.State.drag` (`%{from: path, over: path}` or nil): the tab
  under a tab drag carries `drop_marker` (`View.DropMarker`); no drag, no prop.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.Layout
  alias HerdrServer.View.DropMarker

  @spec node(map, HerdrScene.Scene.rect(), map | nil) :: Node.t()
  def node(ws, rect, drag \\ nil) do
    paths = Enum.map(ws.tabs, &[:tabs, {:tab, &1.id}])

    tabs =
      ws.tabs
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} ->
        active? = t.id == ws.active_tab
        props = %{index: i, active: active?, zoomed: active? and zoomed?(t)}

        %Node{
          role: :tab,
          id: {:tab, t.id},
          text: t.name,
          props: DropMarker.put(props, DropMarker.side(drag, [:tabs, {:tab, t.id}], paths))
        }
      end)

    new = %Node{role: :button, id: :new_tab, props: %{action: :new_tab}}
    %Node{role: :tabs, id: :tabs, rect: rect, children: tabs ++ [new]}
  end

  defp zoomed?(t), do: Layout.zoomed?(t.layout, Map.get(t, :zoom))
end
