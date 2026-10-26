defmodule DynideServer.View.DropMarker do
  @moduledoc """
  The `drop_marker` prop (pure) of the node under a client's drag (`Client.State.drag`),
  shared by `View.Tabs` and `View.Sidebar`.
  """

  @doc """
  The drop side for the node at `path` among sibling `paths` while `drag` is over it:
  `:after` when the dragged node comes before it (it lands after), `:before` when after,
  nil otherwise (no drag, not over `path`, or over itself).
  """
  @spec side(map | nil, [term], [[term]]) :: :before | :after | nil
  def side(%{from: from, over: path}, path, paths) do
    case {Enum.find_index(paths, &(&1 == from)), Enum.find_index(paths, &(&1 == path))} do
      {i, j} when is_integer(i) and is_integer(j) and i < j -> :after
      {i, j} when is_integer(i) and is_integer(j) and i > j -> :before
      _ -> nil
    end
  end

  def side(_drag, _path, _paths), do: nil

  @doc "`props` with `drop_marker: side`, unchanged for nil (fixtures carry no marker)."
  @spec put(map, :before | :after | nil) :: map
  def put(props, nil), do: props
  def put(props, side), do: Map.put(props, :drop_marker, side)
end
