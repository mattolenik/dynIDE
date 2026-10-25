defmodule HerdrServer.Client.Toasts do
  @moduledoc """
  Pure per-client notification policy (herdr `notification_policy.rs`), used by
  `Client.Session`:

    * An alert whose pane is in the active tab is suppressed while this client's outer
      terminal is not known to be unfocused (`focused != false`): no toast and no done
      sound. The request sound is never suppressed, so such an alert still reaches the
      client as sound only (`title` and `body` nil); a suppressed done alert does not.
    * Otherwise the alert is forwarded whole (the client applies its delivery and sound
      prefs) and, with `ui.toast.delivery` `:herdr`, queued as a toast: newest first,
      at most 8.

  ponytail: no `ui.toast.delay_ms` delay (herdr waits 1 s and re-checks the state);
  add a timer in the session if flicker from fast transitions shows.
  """

  alias HerdrServer.Layout

  @max 8

  @type toast :: %{
          id: pos_integer,
          level: atom,
          title: binary | nil,
          body: binary | nil,
          pane: pos_integer | nil
        }

  @doc "What to send the client (nil: nothing) and the new queue for `alert`."
  @spec alert([toast], map, map, boolean | nil, pos_integer) :: {map | nil, [toast]}
  def alert(toasts, alert, app, focused, id) do
    cond do
      not suppressed?(app, alert.pane, focused) ->
        {alert, queue(toasts, alert, app, id)}

      alert.sound == :request ->
        {%{alert | title: nil, body: nil}, toasts}

      true ->
        {nil, toasts}
    end
  end

  @doc "Takes toast `id` out of the queue (nil when it is gone)."
  @spec drop([toast], term) :: {toast | nil, [toast]}
  def drop(toasts, id) do
    case Enum.split_with(toasts, &(&1.id == id)) do
      {[t], rest} -> {t, rest}
      {_, rest} -> {nil, rest}
    end
  end

  defp queue(toasts, a, %{ui: %{toast: %{delivery: :herdr}}}, id) do
    t = %{id: id, level: a.level, title: a.title, body: a.body, pane: a.pane}
    Enum.take([t | toasts], @max)
  end

  defp queue(toasts, _a, _app, _id), do: toasts

  defp suppressed?(app, pane, focused) do
    ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
    tab = ws && Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    focused != false and tab != nil and pane in Layout.pane_ids(tab.layout)
  end
end
