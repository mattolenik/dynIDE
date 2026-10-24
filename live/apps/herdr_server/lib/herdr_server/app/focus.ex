defmodule HerdrServer.App.Focus do
  @moduledoc "Input focus: focused pane, input mode and the modal stack."

  defstruct pane: nil, mode: :terminal, modal: []

  @type t :: %__MODULE__{
          pane: pos_integer() | nil,
          mode: :terminal | :prefix | :resize,
          modal: list()
        }
end
