defmodule HerdrServer.App.Modal.Confirm do
  @moduledoc """
  The confirmation modal (`%{kind: :confirm, title, detail, tone, on_confirm: {M, F, A}}`)
  and the close actions that open it (inventory §5).

  Enter or the `:confirm` button runs `apply(m, f, [app | a])` and closes; Esc, the
  `:cancel` button or a backdrop click close without acting. Panel 64x6, title and
  detail lines, buttons `confirm` (Enter, primary) and `cancel` (Esc).

  `close_tab/1,3`, `close_pane/1,2` and `close_workspace/1,2` (the `X`, `x` and `D`
  bindings and the context menus) act in the target's own workspace. An action that
  removes the whole workspace (its last pane or last tab, or the workspace itself)
  closes that workspace (the last one is replaced by a fresh one); `ui.confirm_close`
  only decides whether `"Close workspace?"` (detail `"<name> — 1 pane"` / `"<name> — N
  panes"`) asks first. Other closes act directly.
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
  def close_tab(app), do: close_tab(app, app.session.active_workspace, ws(app).active_tab)

  @doc "Closes tab `tab_id` of workspace `ws_id` (tab ids are per workspace)."
  @spec close_tab(map, term, term) :: {map, [tuple]}
  def close_tab(app, ws_id, tab_id) do
    w = Enum.find(app.session.workspaces, &(&1.id == ws_id))

    cond do
      w == nil or not Enum.any?(w.tabs, &(&1.id == tab_id)) -> {app, []}
      length(w.tabs) == 1 -> whole(app, w)
      true -> within(app, ws_id, &Actions.close_tab(&1, tab_id))
    end
  end

  @spec close_pane(map) :: {map, [tuple]}
  def close_pane(app), do: close_pane(app, app.focus.pane)

  @doc "Closes pane `id` in whichever workspace holds it; unknown ids are a no-op."
  @spec close_pane(map, term) :: {map, [tuple]}
  def close_pane(app, id) do
    found =
      for w <- app.session.workspaces, t <- w.tabs, id in Layout.pane_ids(t.layout), do: {w, t}

    case found do
      [{w, t} | _] when length(w.tabs) == 1 ->
        if Layout.count(t.layout) == 1,
          do: whole(app, w),
          else: within(app, w.id, &Actions.close_pane(&1, id))

      [{w, _t} | _] ->
        within(app, w.id, &Actions.close_pane(&1, id))

      [] ->
        {app, []}
    end
  end

  @spec close_workspace(map) :: {map, [tuple]}
  def close_workspace(app), do: close_workspace(app, app.session.active_workspace)

  @spec close_workspace(map, term) :: {map, [tuple]}
  def close_workspace(app, ws_id) do
    case Enum.find(app.session.workspaces, &(&1.id == ws_id)) do
      nil -> {app, []}
      w -> whole(app, w)
    end
  end

  @doc """
  Closes workspace `ws_id` (the confirmed action, or the direct one with
  `confirm_close` off); the active workspace stays active unless it is the one closed.
  Gone already is a no-op.
  """
  @spec close_workspace_now(map, term) :: {map, [tuple]}
  def close_workspace_now(app, ws_id) do
    if Enum.any?(app.session.workspaces, &(&1.id == ws_id)),
      do: within(app, ws_id, &Workspaces.close_workspace/1),
      else: {app, []}
  end

  # the action removes workspace `w`: ask when confirm_close, else close it; the same
  # close either way
  defp whole(app, w) do
    if app.ui.confirm_close do
      n = Enum.sum(Enum.map(w.tabs, &Layout.count(&1.layout)))
      detail = "#{w.name} — #{n} #{if n == 1, do: "pane", else: "panes"}"
      modal = new("Close workspace?", detail, :danger, {__MODULE__, :close_workspace_now, [w.id]})
      {Modal.push(app, modal), []}
    else
      close_workspace_now(app, w.id)
    end
  end

  # runs `fun` with workspace `ws_id` active, then re-activates the one that was active
  # (when it still exists)
  defp within(app, ws_id, fun) do
    back = app.session.active_workspace
    {app, []} = Workspaces.switch_workspace_id(app, ws_id)
    {app, effects} = fun.(app)

    case Workspaces.switch_workspace_id(app, back) do
      {app, []} -> {app, effects}
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
