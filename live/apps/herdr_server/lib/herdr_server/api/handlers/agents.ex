defmodule HerdrServer.Api.Handlers.Agents do
  @moduledoc "Every `agent.*` method answers `not_available` until M11 detection lands."

  @spec handle(String.t(), map()) :: {:error, :not_available, String.t(), map()}
  def handle(_method, _params),
    do:
      {:error, :not_available, "agent state needs detection (M11)",
       %{"requires" => "M11 detection"}}
end
