defmodule HerdrServer.App.Ui do
  @moduledoc "UI configuration carried in app state."

  defstruct [:keybinds, status: %{show_hints: true}, theme: :default]

  @type t :: %__MODULE__{
          keybinds: HerdrServer.App.Keybinds.t(),
          status: %{show_hints: boolean()},
          theme: atom()
        }
end
