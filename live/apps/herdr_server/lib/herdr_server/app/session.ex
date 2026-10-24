defmodule HerdrServer.App.Session do
  @moduledoc """
  Session organisation: workspaces, tabs (each owning a `HerdrServer.Layout`), per-pane
  metadata. `size` is the driving client's size and `area` its pane area, the `panes` rect
  of `View.Frame.regions(size, ui)` (sidebar, tab bar and status row excluded).
  """

  alias HerdrServer.Layout

  defstruct workspaces: [],
            active_workspace: nil,
            panes: %{},
            next_id: 1,
            size: %{cols: 80, rows: 24},
            area: %{x: 26, y: 1, w: 54, h: 22}

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
          size: %{cols: pos_integer(), rows: pos_integer()},
          area: Layout.rect()
        }
end
