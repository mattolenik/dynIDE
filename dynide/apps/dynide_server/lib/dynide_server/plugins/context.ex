defmodule DynideServer.Plugins.Context do
  @moduledoc """
  herdr's `PluginInvocationContext` (string keys, nil fields omitted) for a command: the
  workspace, tab and pane a plugin runs against. The pane's agent and its status come
  from its session meta (the published status, `done` included). Pure; the pane cwd comes from
  `extra[:cwd_of]` (default: the pane's pty, as `Persist.Facts` reads it). Other string
  keys of `extra` that name a context field win over the built ones (herdr's merge).
  """

  alias DynideServer.Api.Ids
  alias DynideServer.App.Commands
  alias DynideServer.Kernel
  alias DynideServer.Pane.Rows

  @fields ~w(workspace_id workspace_label workspace_cwd tab_id tab_label focused_pane_id
             focused_pane_cwd focused_pane_agent focused_pane_agent_status invocation_source correlation_id clicked_url link_handler_id
             click_modifiers)

  @type t :: %{String.t() => term()}

  @doc "Context for pane `pane` (nil: the focused pane) invoked from `source`."
  @spec build(map() | nil, pos_integer() | nil, String.t(), map()) :: t()
  def build(app, pane, source, extra \\ %{}) do
    base = %{"invocation_source" => source, "correlation_id" => source}

    app
    |> located(pane || focused(app))
    |> pane_fields(app, Map.get(extra, :cwd_of, &pane_cwd/1))
    |> Map.merge(base)
    |> Map.merge(Map.take(extra, @fields))
    |> drop_nils()
  end

  @doc "The pane a menu target stands for: the pane, a tab's or workspace's focused pane."
  @spec target_pane(map() | nil, {atom(), term()}) :: pos_integer() | nil
  def target_pane(%{session: _} = app, {:pane, id}), do: if(Commands.locate(app, id), do: id)

  def target_pane(%{session: s}, {:tab, id}), do: tab_focus(s, s.active_workspace, id)

  def target_pane(%{session: s}, {:workspace, id}) do
    case Enum.find(s.workspaces, &(&1.id == id)) do
      nil -> nil
      ws -> tab_focus(s, id, ws.active_tab)
    end
  end

  def target_pane(_app, _target), do: nil

  @doc """
  Context for an API event (herdr's `plugin_context_for_event`): the event's pane, else
  its tab's focused pane, else its workspace's; a target no longer in `app` gives only
  the event's ids. Source `"api"`, correlation id the event name.
  """
  @spec for_event(map() | nil, map(), map()) :: t()
  def for_event(app, event, extra \\ %{}) do
    name = event["event"]
    extra = Map.put(extra, "correlation_id", name)

    case event_pane(app, event) do
      nil ->
        event
        |> Map.take(~w(workspace_id tab_id))
        |> Map.merge(%{"invocation_source" => "api", "correlation_id" => name})
        |> Map.merge(Map.take(event, ["pane_id"]) |> rename("pane_id", "focused_pane_id"))

      pane ->
        build(app, pane, "api", extra)
    end
  end

  # --- internals ---

  defp event_pane(nil, _event), do: nil

  defp event_pane(app, event) do
    with :error <- parsed(event["pane_id"], &Ids.parse_pane/1, &target_pane(app, {:pane, &1})),
         :error <- parsed(event["tab_id"], &Ids.parse_tab/1, &tab_focus(app.session, &1)),
         :error <-
           parsed(event["workspace_id"], &Ids.parse_workspace/1, &ws_target(app, event, &1)) do
      nil
    end
  end

  # workspace events only: a tab or pane event whose own target is gone has none
  defp ws_target(app, event, id) do
    if event["tab_id"] == nil and event["pane_id"] == nil,
      do: target_pane(app, {:workspace, id})
  end

  defp parsed(nil, _parse, _f), do: :error

  defp parsed(v, parse, f) do
    with {:ok, id} <- parse.(v), p when p != nil <- f.(id), do: p, else: (_ -> :error)
  end

  defp tab_focus(s, {w, t}), do: tab_focus(s, w, t)

  defp tab_focus(s, w, t) do
    with %{} = ws <- Enum.find(s.workspaces, &(&1.id == w)),
         %{} = tab <- Enum.find(ws.tabs, &(&1.id == t)) do
      tab.layout.focus
    else
      _ -> nil
    end
  end

  defp focused(nil), do: nil
  defp focused(%{session: s}), do: tab_focus(s, s.active_workspace, active_tab(s))

  defp active_tab(s) do
    case Enum.find(s.workspaces, &(&1.id == s.active_workspace)) do
      nil -> nil
      ws -> ws.active_tab
    end
  end

  defp located(nil, _pane), do: nil
  defp located(_app, nil), do: nil

  defp located(app, pane) do
    with {w, t} <- Commands.locate(app, pane),
         %{} = ws <- Enum.find(app.session.workspaces, &(&1.id == w)),
         %{} = tab <- Enum.find(ws.tabs, &(&1.id == t)) do
      {ws, tab, pane}
    else
      _ -> nil
    end
  end

  defp pane_fields(nil, _app, _cwd_of), do: %{}

  defp pane_fields({ws, tab, pane}, app, cwd_of) do
    cwd = cwd_of.(pane)
    meta = app.session.panes[pane] || %{}
    status = Map.get(meta, :agent_state)

    %{
      "workspace_id" => Ids.workspace(ws.id),
      "workspace_label" => ws.name,
      "workspace_cwd" => cwd || File.cwd!(),
      "tab_id" => Ids.tab(ws.id, tab.id),
      "tab_label" => tab.name,
      "focused_pane_id" => Ids.pane(pane),
      "focused_pane_cwd" => cwd,
      "focused_pane_agent" => Map.get(meta, :agent),
      "focused_pane_agent_status" => status && Atom.to_string(status)
    }
  end

  defp rename(m, from, to) do
    case Map.pop(m, from) do
      {nil, m} -> m
      {v, m} -> Map.put(m, to, v)
    end
  end

  defp drop_nils(m), do: Map.reject(m, fn {_, v} -> v == nil end)

  @doc false
  # the pane's process cwd, as `Persist.Facts` reads it
  @spec pane_cwd(pos_integer()) :: String.t() | nil
  def pane_cwd(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{pty: pty}} <- Kernel.keeper().lookup(kid) do
      Kernel.pty().cwd(pty)
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
