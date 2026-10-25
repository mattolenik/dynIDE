defmodule HerdrServer.App.Focus do
  @moduledoc """
  Shared input focus: focused pane and modal stack. Input mode and consumed-press keys
  are per-client (`Client.State`, resolved by `Client.Keys`).

  `modal` is the stack, top first: plain maps `%{kind: atom, id: pos_integer, ...}`
  (callbacks as `{M, F, A}`), managed by `App.Modal`. Every attached client sees and can
  answer the top one. `next_modal_id` is the next modal's id (`App.Modal.push/2`), never
  reused, so a stale scene's modal path cannot match a later modal.
  """

  defstruct pane: nil, modal: [], next_modal_id: 1

  @type t :: %__MODULE__{
          pane: pos_integer() | nil,
          modal: [map()],
          next_modal_id: pos_integer()
        }
end
