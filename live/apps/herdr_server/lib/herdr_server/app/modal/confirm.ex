defmodule HerdrServer.App.Modal.Confirm do
  @moduledoc """
  The confirmation modal (`%{kind: :confirm, title, detail, tone, on_confirm: {M, F, A}}`)
  and the close actions that open it (inventory §5).

  Enter or the `:confirm` button runs `apply(m, f, [app | a])` and closes; Esc, the
  `:cancel` button or a backdrop click close without acting. Panel 64x6, title and
  detail lines, buttons `confirm` (Enter, primary) and `cancel` (Esc).

  `close_tab/1,2`, `close_pane/1,2` and `close_workspace/1,2` (the `X`, `x` and `D`
  bindings and the context menus) ask `"Close workspace?"` with detail `"<name> — 1
  pane"` / `"<name> — N panes"` only when `ui.confirm_close` is set and the action would
  remove the whole workspace (its last pane or last tab, or the workspace itself);
  confirming closes the workspace. Otherwise they act directly.
  """

  @behaviour HerdrServer.App.Modal.Kind

  alias HerdrServer.App.{Actions, Modal, Workspaces}
  alias HerdrServer.Layout
  alias HerdrServer.View.Modal, as: V

  @spec new(binary, binary, :default | :danger, {module, atom, list}) :: map
  def new(title, detail, tone, on_confirm),
    do: %{kind: :confirm, title: title, detail: detail, tone: tone, on_confirm: on_confirm}

  # --- close actions ---

  @spec close_tab(map) :: {map, [tuple]}
  def close_tab(app), do: close_tab(app, ws(app).active_tab)

  @spec close_tab(map, term) :: {map, [tuple]}
  def close_tab(app, tab_id) do
    w = ws(app)

    cond do
      not Enum.any?(w.tabs, &(&1.id == tab_id)) -> {app, []}
      length(w.tabs) == 1 -> ask(app, w, {Actions, :close_tab, [tab_id]})
      true -> Actions.close_tab(app, tab_id)
    end
  end

  @spec close_pane(map) :: {map, [tuple]}
  def close_pane(app), do: close_pane(app, app.focus.pane)

  @spec close_pane(map, term) :: {map, [tuple]}
  def close_pane(app, id) do
    w = ws(app)

    case Enum.find(w.tabs, &(id in Layout.pane_ids(&1.layout))) do
      nil -> {app, []}
      t when length(w.tabs) == 1 -> if_last(app, w, t, id)
      _t -> Actions.close_pane(app, id)
    end
  end

  defp if_last(app, w, t, id) do
    if Layout.count(t.layout) == 1,
      do: ask(app, w, {Actions, :close_pane, [id]}),
      else: Actions.close_pane(app, id)
  end

  @spec close_workspace(map) :: {map, [tuple]}
  def close_workspace(app), do: close_workspace(app, app.session.active_workspace)

  @spec close_workspace(map, term) :: {map, [tuple]}
  def close_workspace(app, ws_id) do
    case Enum.find(app.session.workspaces, &(&1.id == ws_id)) do
      nil -> {app, []}
      w -> ask(app, w, nil)
    end
  end

  @doc "Closes workspace `ws_id` (the confirmed action); gone already is a no-op."
  @spec close_workspace_now(map, term) :: {map, [tuple]}
  def close_workspace_now(app, ws_id) do
    if Enum.any?(app.session.workspaces, &(&1.id == ws_id)) do
      {app, []} = Workspaces.switch_workspace_id(app, ws_id)
      Workspaces.close_workspace(app)
    else
      {app, []}
    end
  end

  # confirm_close off: `direct` (or the workspace close itself)
  defp ask(app, w, direct) do
    if app.ui.confirm_close do
      n = Enum.sum(Enum.map(w.tabs, &Layout.count(&1.layout)))
      detail = "#{w.name} — #{n} #{if n == 1, do: "pane", else: "panes"}"
      modal = new("Close workspace?", detail, :danger, {__MODULE__, :close_workspace_now, [w.id]})
      {Modal.push(app, modal), []}
    else
      {m, f, a} = direct || {__MODULE__, :close_workspace_now, [w.id]}
      apply(m, f, [app | a])
    end
  end

  # --- kind ---

  @impl true
  def key(m, {:key, %{key: :enter}}, app), do: confirm(m, app)
  def key(m, _ev, _app), do: {:keep, m}

  @impl true
  def chrome(m, [:actions, :confirm], {:click, _}, app), do: confirm(m, app)
  def chrome(_m, [:actions, :cancel], {:click, _}, app), do: {:close, app, []}
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(m, _app, size) do
    V.modal(:confirm, V.panel(size, 64, 6), m.tone, [
      V.title(m.title, if(m.tone == :danger, do: :error, else: :strong)),
      V.line(0, m.detail),
      V.actions([{:confirm, "confirm", :enter, []}, {:cancel, "cancel", :escape, []}])
    ])
  end

  defp confirm(%{on_confirm: {mod, f, a}}, app) do
    {app, effects} = apply(mod, f, [app | a])
    {:close, app, effects}
  end

  defp ws(%{session: s}), do: Enum.find(s.workspaces, &(&1.id == s.active_workspace))
end
