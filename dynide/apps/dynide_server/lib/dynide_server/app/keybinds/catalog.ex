defmodule DynideServer.App.Keybinds.Catalog do
  @moduledoc """
  herdr's `[keys]` actions that dynIDE has (inventory §8): action name, keybinds
  modal group, the binding's `{M, F, A}` as `App.Keybinds.default/0` holds it, and
  herdr's default specs (`Config.Keys` syntax). Groups in display order: `global`,
  `navigation`, `workspaces / tabs`, `panes`.

  Left out until their targets land: `workspace_picker` and the indexed
  `switch_tab` (`prefix+1..9`, kept as defaults but not rebindable here). A nil spec is
  unbound by default (`open_worktree`, `remove_worktree`).
  """

  alias DynideServer.App.Actions
  alias DynideServer.App.Modal.{Confirm, Goto, Menu, Prompt, Settings}
  alias DynideServer.App.Modal.Keybinds, as: KeybindsModal
  alias DynideServer.Client.Keys

  @type entry :: %{
          action: binary,
          group: binary,
          mfa: DynideServer.App.Keybinds.mfa_t(),
          default: [binary]
        }

  @spec entries() :: [entry]
  def entries do
    [
      {"global", "help", {KeybindsModal, :open, []}, "prefix+?"},
      {"global", "settings", {Settings, :open, []}, "prefix+s"},
      {"global", "detach", a(:detach), "prefix+q"},
      {"global", "reload_config", a(:reload_config), "prefix+shift+r"},
      {"navigation", "focus_pane_left", a(:focus_dir, [:left]), "prefix+h"},
      {"navigation", "focus_pane_down", a(:focus_dir, [:down]), "prefix+j"},
      {"navigation", "focus_pane_up", a(:focus_dir, [:up]), "prefix+k"},
      {"navigation", "focus_pane_right", a(:focus_dir, [:right]), "prefix+l"},
      {"navigation", "cycle_pane_next", a(:cycle, [:next]), "prefix+tab"},
      {"navigation", "cycle_pane_previous", a(:cycle, [:previous]), "prefix+shift+tab"},
      {"navigation", "goto", {Goto, :open, []}, "prefix+g"},
      {"navigation", "navigate_workspaces", {Keys, :enter_mode, [:navigate]}, "prefix+w"},
      {"workspaces / tabs", "new_workspace", a(:new_workspace), "prefix+shift+n"},
      {"workspaces / tabs", "rename_workspace", {Prompt, :rename_workspace, []},
       "prefix+shift+w"},
      {"workspaces / tabs", "close_workspace", {Confirm, :close_workspace, []}, "prefix+shift+d"},
      {"workspaces / tabs", "new_tab", {Prompt, :new_tab, []}, "prefix+c"},
      {"workspaces / tabs", "rename_tab", {Prompt, :rename_tab, []}, "prefix+shift+t"},
      {"workspaces / tabs", "previous_tab", a(:previous_tab), "prefix+p"},
      {"workspaces / tabs", "next_tab", a(:next_tab), "prefix+n"},
      {"workspaces / tabs", "close_tab", {Confirm, :close_tab, []}, "prefix+shift+x"},
      {"workspaces / tabs", "new_worktree", {Prompt, :new_worktree, []}, "prefix+shift+g"},
      {"workspaces / tabs", "open_worktree", {Menu, :open_worktree, []}, nil},
      {"workspaces / tabs", "remove_worktree", {Confirm, :remove_worktree, []}, nil},
      {"panes", "split_vertical", a(:split, [:horizontal]), "prefix+v"},
      {"panes", "split_horizontal", a(:split, [:vertical]), "prefix+minus"},
      {"panes", "close_pane", {Confirm, :close_pane, []}, "prefix+x"},
      {"panes", "rename_pane", {Prompt, :rename_pane, []}, "prefix+shift+p"},
      {"panes", "swap_pane_left", a(:swap_dir, [:left]), "prefix+shift+h"},
      {"panes", "swap_pane_down", a(:swap_dir, [:down]), "prefix+shift+j"},
      {"panes", "swap_pane_up", a(:swap_dir, [:up]), "prefix+shift+k"},
      {"panes", "swap_pane_right", a(:swap_dir, [:right]), "prefix+shift+l"},
      {"panes", "resize_mode", {Keys, :enter_mode, [:resize]}, "prefix+r"},
      {"panes", "copy_mode", {Keys, :enter_mode, [:copy]}, "prefix+["},
      {"panes", "toggle_sidebar", a(:toggle_sidebar), "prefix+b"},
      {"panes", "zoom", a(:toggle_zoom), "prefix+z"}
    ]
    |> Enum.map(fn {g, action, mfa, spec} ->
      %{action: action, group: g, mfa: mfa, default: List.wrap(spec)}
    end)
  end

  @spec find(binary) :: entry | nil
  def find(action), do: Enum.find(entries(), &(&1.action == action))

  @doc "The keybinds modal's label: herdr's help label (`help` is `keybinds`)."
  @spec label(binary) :: binary
  def label("help"), do: "keybinds"
  def label(action), do: String.replace(action, "_", " ")

  defp a(fun, args \\ []), do: {Actions, fun, args}
end
