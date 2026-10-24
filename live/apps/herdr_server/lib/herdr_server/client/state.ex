defmodule HerdrServer.Client.State do
  @moduledoc "State of one attached client connection (used by `Client.Session`)."

  defstruct [
    :kind,
    :transport,
    :size,
    :cell_px,
    :caps,
    :client,
    viewports: %{},
    hover: nil,
    last_scene: nil,
    monitor: nil
  ]

  @type t :: %__MODULE__{
          kind: term(),
          transport: term(),
          size: term(),
          cell_px: {pos_integer(), pos_integer()} | nil,
          caps: term(),
          client: pid() | nil,
          viewports: map(),
          hover: term(),
          last_scene: term(),
          monitor: reference() | nil
        }
end
