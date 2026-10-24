defmodule HerdrServer.Pane.State do
  @moduledoc "State of one pane process (used by `Pane.Server`)."

  defstruct [
    :id,
    pty: nil,
    vt: nil,
    gen: 0,
    layout_gen: 0,
    rows: {},
    cursor: nil,
    hidden: false,
    title: nil
  ]

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          pty: term(),
          vt: term(),
          gen: non_neg_integer(),
          layout_gen: non_neg_integer(),
          rows: tuple(),
          cursor: map() | nil,
          hidden: boolean(),
          title: binary() | nil
        }
end
