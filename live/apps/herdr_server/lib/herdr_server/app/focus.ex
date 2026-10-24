defmodule HerdrServer.App.Focus do
  @moduledoc "Input focus: focused pane, input mode, modal stack and consumed-press keys (`swallow`)."

  defstruct pane: nil, mode: :terminal, modal: [], swallow: MapSet.new()

  @type t :: %__MODULE__{
          pane: pos_integer() | nil,
          mode: :terminal | :prefix | :resize,
          modal: list(),
          swallow: MapSet.t()
        }
end
