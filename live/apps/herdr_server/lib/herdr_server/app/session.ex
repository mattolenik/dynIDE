defmodule HerdrServer.App.Session do
  @moduledoc """
  Session organisation: workspaces, tabs (each owning a `HerdrServer.Layout`), per-pane
  metadata. `area` is the driving client's pane area (status row excluded).
  """

  alias HerdrServer.Layout

  defstruct workspaces: [],
            active_workspace: nil,
            panes: %{},
            next_id: 1,
            area: %{x: 0, y: 0, w: 80, h: 23}

  @type tab :: %{id: pos_integer(), name: binary(), layout: Layout.t()}
  @type workspace :: %{
          id: pos_integer(),
          name: binary(),
          tabs: [tab()],
          active_tab: pos_integer()
        }
  @type t :: %__MODULE__{
          workspaces: [workspace()],
          active_workspace: pos_integer() | nil,
          panes: %{pos_integer() => %{title: binary() | nil, layout_gen: non_neg_integer()}},
          next_id: pos_integer(),
          area: Layout.rect()
        }
end
