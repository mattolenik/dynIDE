defmodule HerdrServer.View.Tabs do
  @moduledoc """
  The tab bar region: one `:tab` per tab of the workspace (`props: %{index, active,
  zoomed}`, 1-based index) and a trailing `:button` `:new_tab`. Pure.
  """

  alias HerdrScene.Scene.Node

  @spec node(map, HerdrScene.Scene.rect()) :: Node.t()
  def node(ws, rect) do
    tabs =
      ws.tabs
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} ->
        %Node{
          role: :tab,
          id: {:tab, t.id},
          text: t.name,
          props: %{index: i, active: t.id == ws.active_tab, zoomed: false}
        }
      end)

    new = %Node{role: :button, id: :new_tab, props: %{action: :new_tab}}
    %Node{role: :tabs, id: :tabs, rect: rect, children: tabs ++ [new]}
  end
end
