defmodule HerdrServer.Plugins.Alert do
  @moduledoc "A plugin problem as one log line and one toast (M13's alert path), pane-less."

  require Logger

  alias HerdrServer.App.Store

  @spec show(String.t()) :: :ok
  def show(text) do
    Logger.warning("plugin: " <> text)
    if Process.whereis(Store), do: Store.request({__MODULE__, :effect, [text]})
    :ok
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
