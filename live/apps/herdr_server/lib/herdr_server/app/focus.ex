defmodule HerdrServer.App.Focus do
  @moduledoc """
  Shared input focus: focused pane and modal stack. Input mode and consumed-press keys
  are per-client (`Client.State`, resolved by `Client.Keys`).
  """

  defstruct pane: nil, modal: []

  @type t :: %__MODULE__{pane: pos_integer() | nil, modal: list()}
end
