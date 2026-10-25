defmodule HerdrServer.App.Modal.Prompt do
  @moduledoc """
  The name prompt (`%{kind: :prompt, title, field: TextField.t(), on_submit: {M, F, A}}`)
  and the actions that open it (inventory §5: titles `"new tab"`, `"rename tab"`,
  `"rename workspace"`, `"rename pane"`; panel 56x7).

  Typing edits the field (`TextField`, at most 64 graphemes); ctrl+c or the `:clear`
  button empties it; Enter or `:save` submits the text trimmed of surrounding
  whitespace as the last argument, `apply(m, f, [app | a ++ [text]])`, and closes. An
  empty name keeps the prompt open. Esc, `:cancel` or a backdrop click cancel.

  `new_tab/1` (the `c` binding and the tab bar's `+`) asks for the name, prefilled with
  the next tab number, when `ui.prompt_new_tab_name` is set, else opens the tab directly.

  `new_worktree/1` (`prefix+G`) asks for a branch name (title `"new worktree"`); submitting
  emits `{:worktree, :create, %{pane: root, branch: name}}` (`App.Worktrees.create/3`) for
  the active workspace's repo.
  """

  @behaviour HerdrServer.App.Modal.Kind

  alias HerdrServer.App.{Actions, Modal, Worktrees}
  alias HerdrServer.App.Modal.TextField
  alias HerdrServer.View.Modal, as: V

  @spec new(binary, binary, {module, atom, list}) :: map
  def new(title, text, on_submit),
    do: %{kind: :prompt, title: title, field: TextField.new(text), on_submit: on_submit}

  # --- openers ---

  @spec new_tab(map) :: {map, [tuple]}
  def new_tab(app) do
    if app.ui.prompt_new_tab_name do
      open(app, new("new tab", Actions.tab_name(ws(app).tabs), {__MODULE__, :create_tab, []}))
    else
      Actions.new_tab(app)
    end
  end

  @doc "Opens a tab named `name` (the submitted new-tab prompt)."
  @spec create_tab(map, binary) :: {map, [tuple]}
  def create_tab(app, name) do
    {app, effects} = Actions.new_tab(app)
    {app, []} = Actions.rename_tab(app, app.session.active_workspace, ws(app).active_tab, name)
    {app, effects}
  end

  @spec new_worktree(map) :: {map, [tuple]}
  def new_worktree(app),
    do: open(app, new("new worktree", "", {Worktrees, :create, [Worktrees.root_pane(ws(app))]}))

  @spec rename_tab(map) :: {map, [tuple]}
  def rename_tab(app), do: rename_tab(app, app.session.active_workspace, ws(app).active_tab)

  @doc "Asks for a new name of tab `tab_id` of workspace `ws_id` (both carried in the MFA)."
  @spec rename_tab(map, term, term) :: {map, [tuple]}
  def rename_tab(app, ws_id, tab_id) do
    with %{tabs: tabs} <- Enum.find(app.session.workspaces, &(&1.id == ws_id)),
         %{name: name} <- Enum.find(tabs, &(&1.id == tab_id)) do
      open(app, new("rename tab", name, {Actions, :rename_tab, [ws_id, tab_id]}))
    else
      _ -> {app, []}
    end
  end

  @spec rename_workspace(map) :: {map, [tuple]}
  def rename_workspace(app), do: rename_workspace(app, app.session.active_workspace)

  @spec rename_workspace(map, term) :: {map, [tuple]}
  def rename_workspace(app, ws_id) do
    case Enum.find(app.session.workspaces, &(&1.id == ws_id)) do
      nil -> {app, []}
      w -> open(app, new("rename workspace", w.name, {Actions, :rename_workspace, [ws_id]}))
    end
  end

  @spec rename_pane(map) :: {map, [tuple]}
  def rename_pane(app), do: rename_pane(app, app.focus.pane)

  @spec rename_pane(map, term) :: {map, [tuple]}
  def rename_pane(app, id) do
    case app.session.panes do
      %{^id => meta} ->
        open(app, new("rename pane", Map.get(meta, :name) || "", {Actions, :rename_pane, [id]}))

      _ ->
        {app, []}
    end
  end

  defp open(app, modal), do: {Modal.push(app, modal), []}

  # --- kind ---

  @impl true
  def key(m, {:key, %{key: :enter}}, app), do: submit(m, app)
  def key(m, {:key, %{key: "c", mods: [:ctrl]}}, _app), do: {:keep, clear(m)}

  def key(m, ev, _app) do
    case TextField.key(m.field, ev) do
      {:ok, f} -> {:keep, %{m | field: f}}
      :ignore -> {:keep, m}
    end
  end

  @impl true
  def chrome(m, [:actions, :save], {:click, _}, app), do: submit(m, app)
  def chrome(m, [:actions, :clear], {:click, _}, _app), do: {:keep, clear(m)}
  def chrome(_m, [:actions, :cancel], {:click, _}, app), do: {:close, app, []}
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(m, _app, size) do
    rect = V.panel(size, 56, 7)

    V.modal(:prompt, rect, :default, [
      V.title(m.title),
      V.input(m.field, rect.w),
      V.actions([
        {:save, "save", :enter, []},
        {:clear, "clear", "c", [:ctrl]},
        {:cancel, "cancel", :escape, []}
      ])
    ])
  end

  defp clear(m), do: %{m | field: TextField.clear(m.field)}

  defp submit(%{field: %{text: text}, on_submit: {mod, f, a}} = m, app) do
    case String.trim(text) do
      "" ->
        {:keep, m}

      name ->
        {app, effects} = apply(mod, f, [app | a ++ [name]])
        {:close, app, effects}
    end
  end

  defp ws(%{session: s}), do: Enum.find(s.workspaces, &(&1.id == s.active_workspace))
end
