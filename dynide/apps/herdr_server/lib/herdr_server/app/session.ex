defmodule HerdrServer.App.Session do
  @moduledoc """
  Session organisation: workspaces, tabs (each owning a `HerdrServer.Layout`), per-pane
  metadata. `size` is the driving client's size and `area` its pane area, the `panes` rect
  of `View.Frame.regions(size, ui, tabs_count)` (sidebar, tab bar and status row excluded).

  `next_workspace_id` and `next_tab_id` only count up, so a closed workspace's or tab's id
  is never handed out again (tab ids are per workspace; a new workspace's first tab is 1).
  `App.Upgrade.app/1` raises them above every existing id for apps from before them.

  A workspace's `auto_name: true` (new unnamed workspaces) lets `WorkspaceFacts` rename
  it from its root pane's repo or cwd; a missing key counts as false (older apps, a
  restored v3 snapshot). `cwd` is the last root-pane cwd seen, never persisted.
  """

  alias HerdrServer.Layout

  defstruct workspaces: [],
            active_workspace: nil,
            panes: %{},
            next_id: 1,
            next_workspace_id: 1,
            next_tab_id: 1,
            size: %{cols: 80, rows: 24},
            area: %{x: 26, y: 1, w: 54, h: 22}

  @type tab :: %{id: pos_integer(), name: binary(), layout: Layout.t()}
  @type workspace :: %{
          required(:id) => pos_integer(),
          required(:name) => binary(),
          required(:tabs) => [tab()],
          required(:active_tab) => pos_integer(),
          optional(:auto_name) => boolean(),
          optional(:cwd) => binary() | nil
        }
  @type t :: %__MODULE__{
          workspaces: [workspace()],
          active_workspace: pos_integer() | nil,
          panes: %{pos_integer() => %{title: binary() | nil, layout_gen: non_neg_integer()}},
          next_id: pos_integer(),
          next_workspace_id: pos_integer(),
          next_tab_id: pos_integer(),
          size: %{cols: pos_integer(), rows: pos_integer()},
          area: Layout.rect()
        }
end
