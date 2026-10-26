defmodule DynideServer.Plugins.Alert do
  @moduledoc """
  A plugin problem as one log line and one toast (M13's alert path), pane-less. Only the
  log line while the Store has no app yet (or is not running).
  """

  require Logger

  alias DynideServer.App.Store

  @spec show(String.t()) :: :ok
  def show(text) do
    Logger.warning("plugin: " <> text)
    # log only before the first client: a request would initialise the session
    if Process.whereis(Store) && snapshot() != nil,
      do: Store.request({__MODULE__, :effect, [text]})

    :ok
  end

  defp snapshot do
    Store.snapshot()
  catch
    :exit, _ -> nil
  end

  @doc false
  def effect(app, text),
    do:
      {app,
       [
         {:alert,
          %{
            kind: :notification,
            level: :attention,
            title: "plugin",
            body: text,
            pane: nil,
            sound: nil
          }}
       ]}
end
