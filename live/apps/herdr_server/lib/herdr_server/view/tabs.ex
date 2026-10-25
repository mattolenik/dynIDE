defmodule HerdrServer.View.Tabs do
  @moduledoc """
  The tab bar region: one `:tab` per tab of the workspace (`props: %{index, active,
  zoomed}`, 1-based index; `zoomed` on the active tab while its zoom holds) and a trailing
  `:button` `:new_tab`. Pure.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.Layout

  @spec node(map, HerdrScene.Scene.rect()) :: Node.t()
  def node(ws, rect) do
    tabs =
      ws.tabs
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} ->
        active? = t.id == ws.active_tab

        %Node{
          role: :tab,
          id: {:tab, t.id},
          text: t.name,
          props: %{index: i, active: active?, zoomed: active? and zoomed?(t)}
        }
      end)

    new = %Node{role: :button, id: :new_tab, props: %{action: :new_tab}}
    %Node{role: :tabs, id: :tabs, rect: rect, children: tabs ++ [new]}
  end

  defp zoomed?(t), do: Layout.zoomed?(t.layout, Map.get(t, :zoom))
end
