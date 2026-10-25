defmodule HerdrServer.Api.Handlers.Topology do
  @moduledoc """
  Handlers for the `workspace`, `tab` and `pane` topology methods. Reads use
  `App.Store.snapshot/0` (initialising a nil app through `Commands.noop/1`); changes go
  through `App.Store.request/1` on `App.Commands` and answer from the `{before, after}`
  pair: the new object is the id present in `after` and not in `before`; a target absent
  from `before` is `not_found`; a warning notice received during the request is `failed`;
  an error notice (the command crashed and the Store discarded or restored the batch) is
  `internal`.
  """

  alias HerdrServer.Api.{Ids, View}
  alias HerdrServer.App.{Commands, Store}
  alias HerdrServer.Kernel
  alias HerdrServer.Layout
  alias HerdrServer.Pane.Rows

  @type reply :: {:ok, map()} | {:error, atom(), String.t()}

  @spec handle(String.t(), map()) :: reply()

  # --- workspaces ---

  def handle("workspace.list", _p) do
    app = app!()

    {:ok,
     %{
       type: "workspace_list",
       workspaces: Enum.map(app.session.workspaces, &View.workspace(app, &1))
     }}
  end

  def handle("workspace.get", %{workspace_id: w}) do
    app = app!()

    with_ws(app, w, fn ws ->
      {:ok, %{type: "workspace_info", workspace: View.workspace(app, ws)}}
    end)
  end

  def handle("workspace.create", p) do
    mfa = {Commands, :create_workspace, [p[:label], Map.get(p, :focus, false)]}

    with {:ok, before, aft, _notes} <- run(mfa) do
      case Enum.reject(aft.session.workspaces, &View.find_workspace(before, &1.id)) do
        [ws | _] -> created_workspace(aft, ws)
        # the command always adds one; only a crash (answered above) adds none
        [] -> {:error, :internal, "no workspace was created"}
      end
    end
  end

  def handle("workspace.focus", %{workspace_id: w}),
    do: change_ws(w, {Commands, :focus_workspace, [w]})

  def handle("workspace.rename", %{workspace_id: w, label: l}),
    do: change_ws(w, {Commands, :rename_workspace, [w, l]})

  def handle("workspace.close", %{workspace_id: w}) do
    with {:ok, before, aft, notes} <- run_on_ws(w, {Commands, :close_workspace, [w]}) do
      ws = View.find_workspace(before, w)

      if gone?(aft, ws_panes(ws)),
        do: {:ok, %{type: "workspace_closed", workspace_id: Ids.workspace(w)}},
        else: unchanged(notes)
    end
  end

  # --- tabs ---

  def handle("tab.list", p) do
    app = app!()

    with {:ok, wss} <- scope_ws(app, p[:workspace_id]) do
      tabs = for ws <- wss, tab <- ws.tabs, do: View.tab(app, ws, tab)
      {:ok, %{type: "tab_list", tabs: tabs}}
    end
  end

  def handle("tab.get", %{tab_id: t}) do
    app = app!()

    with_tab(app, t, fn ws, tab -> {:ok, %{type: "tab_info", tab: View.tab(app, ws, tab)}} end)
  end

  def handle("tab.create", p), do: create_tab(p)

  def handle("tab.focus", %{tab_id: {w, t} = id}),
    do: change_tab(id, {Commands, :focus_tab, [w, t]})

  def handle("tab.rename", %{tab_id: {w, t} = id, label: l}),
    do: change_tab(id, {Commands, :rename_tab, [w, t, l]})

  def handle("tab.close", %{tab_id: {w, t} = id}) do
    with {:ok, before, aft, notes} <- run_on_tab(id, {Commands, :close_tab, [w, t]}) do
      {_ws, tab} = View.find_tab(before, w, t)

      if gone?(aft, Layout.pane_ids(tab.layout)),
        do: {:ok, %{type: "tab_closed", tab_id: Ids.tab(w, t)}},
        else: unchanged(notes)
    end
  end

  # --- panes ---

  def handle("pane.list", p) do
    app = app!()

    with {:ok, wss} <- scope_ws(app, p[:workspace_id]),
         {:ok, tabs} <- scope_tabs(app, wss, p[:tab_id]) do
      {:ok,
       %{
         type: "pane_list",
         panes: for({ws, tab} <- tabs, pane <- View.panes(app, ws, tab), do: pane)
       }}
    end
  end

  def handle("pane.get", %{pane_id: id}), do: pane_info(app!(), id)

  def handle("pane.current", p) do
    app = app!()
    pane_info(app, p[:caller_pane_id] || app.focus.pane)
  end

  def handle("pane.split", p) do
    app = app!()
    id = p[:pane_id] || app.focus.pane
    dir = if p.direction == "right", do: :horizontal, else: :vertical
    ratio = (p[:ratio] || 0.5) * 1.0

    with {:ok, before, aft, notes} <-
           run_on_pane(id, {Commands, :split_pane, [id, dir, ratio, Map.get(p, :focus, false)]}) do
      case Map.keys(aft.session.panes) -- Map.keys(before.session.panes) do
        [new | _] -> pane_reply("pane_split", aft, new)
        [] -> unchanged(notes)
      end
    end
  end

  def handle("pane.close", %{pane_id: id}) do
    with {:ok, _before, aft, notes} <- run_on_pane(id, {Commands, :close_pane, [id]}) do
      if gone?(aft, [id]),
        do: {:ok, %{type: "pane_closed", pane_id: Ids.pane(id)}},
        else: unchanged(notes)
    end
  end

  def handle("pane.focus", %{pane_id: id}) do
    with {:ok, _before, aft, _notes} <- run_on_pane(id, {Commands, :focus_pane, [id]}),
         do: pane_reply("pane_info", aft, id)
  end

  def handle("pane.rename", %{pane_id: id} = p) do
    with {:ok, _before, aft, _notes} <-
           run_on_pane(id, {Commands, :rename_pane, [id, p[:label]]}),
         do: pane_reply("pane_info", aft, id)
  end

  def handle("pane.layout", p) do
    app = app!()
    id = p[:pane_id] || app.focus.pane

    with {ws_id, tab_id} <- Commands.locate(app, id),
         {ws, tab} <- View.find_tab(app, ws_id, tab_id) do
      {:ok, %{type: "pane_layout", layout: View.layout(app, ws, tab)}}
    else
      _ -> not_found(Ids.pane(id))
    end
  end

  def handle("pane.process_info", %{pane_id: id}) do
    app = app!()

    with {_, _} <- Commands.locate(app, id),
         {:ok, facts} <- process_facts(id) do
      {:ok, facts |> Map.put(:type, "process_info") |> Map.put(:pane_id, Ids.pane(id))}
    else
      _ -> not_found(Ids.pane(id))
    end
  end

  # --- workspace and tab helpers ---

  defp created_workspace(aft, ws) do
    tab = hd(ws.tabs)

    {:ok,
     %{
       type: "workspace_created",
       workspace: View.workspace(aft, ws),
       tab: View.tab(aft, ws, tab),
       root_pane: View.pane(aft, tab.layout.focus)
     }}
  end

  defp change_ws(w, mfa) do
    with {:ok, _before, aft, notes} <- run_on_ws(w, mfa) do
      case View.find_workspace(aft, w) do
        nil -> unchanged(notes)
        ws -> {:ok, %{type: "workspace_info", workspace: View.workspace(aft, ws)}}
      end
    end
  end

  defp change_tab({w, t} = id, mfa) do
    with {:ok, _before, aft, notes} <- run_on_tab(id, mfa) do
      case View.find_tab(aft, w, t) do
        {ws, tab} -> {:ok, %{type: "tab_info", tab: View.tab(aft, ws, tab)}}
        nil -> unchanged(notes)
      end
    end
  end

  defp create_tab(p) do
    app = app!()
    w = p[:workspace_id] || app.session.active_workspace
    focus? = Map.get(p, :focus, false)

    with {:ok, before, aft, notes} <-
           run_on_ws(w, {Commands, :create_tab, [w, p[:label], focus?]}) do
      case tab_ids(aft, w) -- tab_ids(before, w) do
        [new | _] -> created_tab(aft, w, new, focus?)
        [] -> unchanged(notes)
      end
    end
  end

  defp created_tab(aft, w, new, focus?) do
    with {:ok, aft} <- focus_new_tab(aft, w, new, focus?) do
      case View.find_tab(aft, w, new) do
        {ws, tab} ->
          {:ok,
           %{
             type: "tab_created",
             tab: View.tab(aft, ws, tab),
             root_pane: View.pane(aft, tab.layout.focus)
           }}

        nil ->
          unchanged([])
      end
    end
  end

  # create_tab with focus only selects the tab; focusing it also activates its workspace
  defp focus_new_tab(aft, _w, _new, false), do: {:ok, aft}

  defp focus_new_tab(_aft, w, new, true) do
    with {:ok, _before, aft, _notes} <- run({Commands, :focus_tab, [w, new]}), do: {:ok, aft}
  end

  defp tab_ids(app, w) do
    case View.find_workspace(app, w) do
      nil -> []
      ws -> Enum.map(ws.tabs, & &1.id)
    end
  end

  defp scope_ws(app, nil), do: {:ok, app.session.workspaces}

  defp scope_ws(app, w) do
    case View.find_workspace(app, w) do
      nil -> not_found(Ids.workspace(w))
      ws -> {:ok, [ws]}
    end
  end

  defp scope_tabs(_app, wss, nil), do: {:ok, for(ws <- wss, tab <- ws.tabs, do: {ws, tab})}

  defp scope_tabs(_app, wss, {w, t}) do
    case for(ws <- wss, ws.id == w, tab <- ws.tabs, tab.id == t, do: {ws, tab}) do
      [] -> not_found(Ids.tab(w, t))
      found -> {:ok, found}
    end
  end

  defp with_ws(app, w, fun) do
    case View.find_workspace(app, w) do
      nil -> not_found(Ids.workspace(w))
      ws -> fun.(ws)
    end
  end

  defp with_tab(app, {w, t}, fun) do
    case View.find_tab(app, w, t) do
      {ws, tab} -> fun.(ws, tab)
      nil -> not_found(Ids.tab(w, t))
    end
  end

  defp ws_panes(ws), do: Enum.flat_map(ws.tabs, &Layout.pane_ids(&1.layout))

  defp pane_info(app, id) do
    case View.pane(app, id) do
      nil -> not_found(Ids.pane(id))
      _ -> pane_reply("pane_info", app, id)
    end
  end

  defp pane_reply(type, app, id) do
    case View.pane(app, id) do
      nil -> not_found(Ids.pane(id))
      pane -> {:ok, %{type: type, pane: pane}}
    end
  end

  # --- process facts ---

  defp process_facts(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{pty: pty}} <- Kernel.keeper().lookup(kid) do
      info = Kernel.pty().info(pty)
      {:ok, %{os_pid: info.os_pid, cwd: info.pwd, exited: info.exited != nil}}
    else
      # the pane's kernel is gone (closing, or never started): not a process to describe
      _ -> :error
    end
  end

  # --- store plumbing ---

  # The current app, initialised first when no client has attached yet.
  @doc false
  @spec app!() :: HerdrServer.App.Actions.app()
  def app! do
    case Store.snapshot() do
      nil ->
        {:ok, _, aft} = Store.request({Commands, :noop, []})
        aft

      app ->
        app
    end
  end

  # {:ok, before, after, warning_texts}. `before` is never nil: the app is initialised first.
  # An error notice means the command crashed (the Store discarded or restored the
  # batch): `internal`, whatever the app shows.
  defp run(mfa) do
    _ = app!()
    {:ok, before, aft} = Store.request(mfa)
    notices = drain()

    case for(%{level: :error, text: t} <- notices, do: t) do
      [text | _] -> {:error, :internal, text}
      [] -> {:ok, before, aft, warnings(notices)}
    end
  end

  defp run_on_ws(w, mfa), do: run_target(mfa, &View.find_workspace(&1, w), Ids.workspace(w))

  defp run_on_tab({w, t}, mfa),
    do: run_target(mfa, fn app -> View.find_tab(app, w, t) end, Ids.tab(w, t))

  defp run_on_pane(id, mfa), do: run_target(mfa, &View.pane(&1, id), Ids.pane(id))

  # A target absent from `before` is not_found, whatever the command did.
  defp run_target(mfa, present, name) do
    with {:ok, before, aft, notes} <- run(mfa) do
      if present.(before), do: {:ok, before, aft, notes}, else: not_found(name)
    end
  end

  defp drain do
    receive do
      {:notice, n} -> [n | drain()]
    after
      0 -> []
    end
  end

  defp warnings(notices),
    do: for(%{level: :warning, text: t} <- notices, do: t)

  defp gone?(aft, pane_ids),
    do: Enum.all?(pane_ids, &(not is_map_key(aft.session.panes, &1)))

  defp unchanged([text | _]), do: {:error, :failed, text}
  defp unchanged([]), do: {:error, :not_found, "the target vanished"}

  defp not_found(name), do: {:error, :not_found, "#{name} not found"}
end
