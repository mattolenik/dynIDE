defmodule HerdrServer.Api.Handlers.Notification do
  @moduledoc "The `notification.show` handler: an `App.Alerts.notify/4` alert to every client."

  alias HerdrServer.App.{Alerts, Commands, Store}

  @spec show(map()) :: {:ok, map()}
  def show(params) do
    if Store.snapshot() == nil, do: Store.request({Commands, :noop, []})

    {:ok, _, _} =
      Store.request({Alerts, :notify, [params.title, params[:body], params[:pane_id]]})

    {:ok, %{type: "ok"}}
  end
end
