defmodule HerdrReload.Batch do
  @moduledoc """
  One reload batch: the modules loaded together plus what is needed to undo it.
  A `nil` previous beam means the module was new in the batch.
  """

  @enforce_keys [:id]
  defstruct id: nil,
            modules: [],
            previous_beams: %{},
            state_at_load: nil,
            loaded_at: 0,
            baseline: %{},
            total_baseline: 0,
            failures: 0,
            rolled_back: false

  @type t :: %__MODULE__{
          id: pos_integer(),
          modules: [module()],
          previous_beams: %{module() => binary() | nil},
          state_at_load: term(),
          loaded_at: integer(),
          baseline: %{module() => non_neg_integer()},
          total_baseline: non_neg_integer(),
          failures: non_neg_integer(),
          rolled_back: boolean()
        }
end
