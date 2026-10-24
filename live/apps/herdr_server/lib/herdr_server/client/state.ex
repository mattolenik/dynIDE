defmodule HerdrServer.Client.State do
  @moduledoc """
  State of one attached client connection (used by `Client.Session`). `mode` and
  `swallow` are this client's input state (`Client.Keys`); `keybinds` caches the app's
  keybinds from the last app the session saw.
  """

  defstruct [
    :kind,
    :transport,
    :size,
    :cell_px,
    :caps,
    :client,
    viewports: %{},
    hover: nil,
    mode: :terminal,
    swallow: MapSet.new(),
    keybinds: nil,
    last_scene: nil,
    monitor: nil,
    store_monitor: nil
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
          mode: :terminal | :prefix | :resize,
          swallow: MapSet.t(),
          keybinds: HerdrServer.App.Keybinds.t() | nil,
          last_scene: term(),
          monitor: reference() | nil,
          store_monitor: reference() | nil
        }
end
