defmodule DynideServer.Client.Drag do
  @moduledoc """
  A client's tab or workspace drag (pure; `Client.Session` calls it through the Guard):
  `%{from: path, over: path}` or nil, kept in `Client.State.drag`.

  `over/2` is the drag for a `:drag` action on `from` whose `over` (the client's hit path
  under the pointer) is another node of the same kind: a tab over a tab
  (`[:tabs, {:tab, _}]`), a workspace item over a workspace item
  (`[:sidebar, :spaces, :list, {:workspace, _}]`). Anything else, malformed terms from a
  socket client included, is nil. `dynide/2` keeps a drag while its `from` still exists in
  the app, else nil (closed mid-drag).
  """

  @type path :: [term()]
  @type t :: %{from: path(), over: path()} | nil

  @spec over(path(), map()) :: t()
  def over([:tabs, {:tab, _}] = from, %{over: [:tabs, {:tab, _}] = over}) when over != from,
    do: %{from: from, over: over}

  def over(
        [:sidebar, :spaces, :list, {:workspace, _}] = from,
        %{over: [:sidebar, :spaces, :list, {:workspace, _}] = over}
      )
      when over != from,
      do: %{from: from, over: over}

  def over(_from, _at), do: nil

  @spec live(t(), map()) :: t()
  def live(%{from: [:tabs, {:tab, id}]} = drag, %{session: s}) do
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    if ws && Enum.any?(ws.tabs, &(&1.id == id)), do: drag
  end

  def live(%{from: [:sidebar, :spaces, :list, {:workspace, id}]} = drag, %{session: s}),
    do: if(Enum.any?(s.workspaces, &(&1.id == id)), do: drag)

  def live(_drag, _app), do: nil
end
