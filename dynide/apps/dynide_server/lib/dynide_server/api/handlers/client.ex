defmodule DynideServer.Api.Handlers.Client do
  @moduledoc """
  `client.window_title.set|clear`: the window title override of every attached client
  (the API has no client target); each `Client.Session` repaints.
  """

  alias DynideServer.View.WindowTitle

  @spec handle(binary, map) :: {:ok, map}
  def handle("client.window_title.set", params),
    do: fan_out(WindowTitle.clean(params.title))

  def handle("client.window_title.clear", _params), do: fan_out(nil)

  defp fan_out(title) do
    for {pid, _} <- Registry.lookup(DynideServer.Client.Registry, :clients),
        do: send(pid, {:window_title, title})

    {:ok, %{type: "ok"}}
  end
end
