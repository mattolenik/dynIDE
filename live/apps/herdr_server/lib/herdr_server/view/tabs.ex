defmodule HerdrServer.View.Tabs do
  @moduledoc """
  The tab bar region: one `:tab` per tab of the workspace (`props: %{index, active,
  zoomed}`, 1-based index; `zoomed` on the active tab while its zoom holds) and a trailing
  `:button` `:new_tab`. Pure.

  `drag` is the client's `Client.State.drag` (`%{from: path, over: path}` or nil): the tab
  under a tab drag carries `drop_marker` (`drop_marker/3`); no drag, no prop.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.Layout

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
          props: put_marker(props, drop_marker(drag, [:tabs, {:tab, t.id}], paths))
        }
      end)

    new = %Node{role: :button, id: :new_tab, props: %{action: :new_tab}}
    %Node{role: :tabs, id: :tabs, rect: rect, children: tabs ++ [new]}
  end

  @doc """
  The drop side for the node at `path` among sibling `paths` while `drag` is over it:
  `:after` when the dragged node comes before it (it lands after), `:before` when after,
  nil otherwise (no drag, not over `path`, or over itself).
  """
  @spec drop_marker(map | nil, [term], [[term]]) :: :before | :after | nil
  def drop_marker(%{from: from, over: path}, path, paths) do
    case {Enum.find_index(paths, &(&1 == from)), Enum.find_index(paths, &(&1 == path))} do
      {i, j} when is_integer(i) and is_integer(j) and i < j -> :after
      {i, j} when is_integer(i) and is_integer(j) and i > j -> :before
      _ -> nil
    end
  end

  def drop_marker(_drag, _path, _paths), do: nil

  @doc "`props` with `drop_marker: side`, unchanged for nil (fixtures carry no marker)."
  @spec put_marker(map, :before | :after | nil) :: map
  def put_marker(props, nil), do: props
  def put_marker(props, side), do: Map.put(props, :drop_marker, side)

  defp zoomed?(t), do: Layout.zoomed?(t.layout, Map.get(t, :zoom))
end
