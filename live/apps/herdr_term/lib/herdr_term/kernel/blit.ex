defmodule HerdrTerm.Kernel.Blit do
  @moduledoc "Cell blitter contract (design.md `Native.Blit`)."

  @type opts :: %{cursor: {non_neg_integer, non_neg_integer} | nil, shape: atom, repaint: boolean}
  @callback frame(HerdrTerm.Kernel.Tty.tty(), [{non_neg_integer, binary}], opts) :: :ok
end
