defmodule HerdrServer.Pane.State do
  @moduledoc """
  State of one pane process (used by `Pane.Server`). `scroll`, `alt_screen`, `cwd`,
  `title` (sanitized), `stripped_title` and `progress` are the pane's terminal facts
  (`Pane.Facts`); `colors` the host colours last applied to the vt; `pending` the
  write queue (Task 4).
  """

  defstruct [
    :id,
    kernel_id: nil,
    pty: nil,
    vt: nil,
    gen: 0,
    layout_gen: 0,
    rows: {},
    cursor: nil,
    hidden: false,
    title: nil,
    scroll: %{total: 0, viewport: 0, offset: 0},
    alt_screen: false,
    cwd: nil,
    progress: nil,
    stripped_title: nil,
    pending: :queue.new(),
    colors: nil
  ]

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          kernel_id: pos_integer() | nil,
          pty: term(),
          vt: term(),
          gen: non_neg_integer(),
          layout_gen: non_neg_integer(),
          rows: tuple(),
          cursor: map() | nil,
          hidden: boolean(),
          title: binary() | nil,
          scroll: %{
            total: non_neg_integer(),
            viewport: non_neg_integer(),
            offset: non_neg_integer()
          },
          alt_screen: boolean(),
          cwd: binary() | nil,
          progress: binary() | nil,
          stripped_title: binary() | nil,
          pending: :queue.queue(),
          colors: map() | nil
        }
end
