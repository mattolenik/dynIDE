defmodule DynideServer.Throttle do
  @moduledoc """
  A leading- and trailing-edge throttle's state, pure (the caller owns the timer). `nil`
  is idle; `:armed` a window open with nothing due; `:due` a window open with work held
  back. `hit/1` is a new event, `tick/1` the window's timer firing. `:fire` means do the
  work now and arm one window timer; `:skip` means do nothing.
  """

  @type t :: nil | :armed | :due

  @spec hit(t) :: {:fire | :skip, t}
  def hit(nil), do: {:fire, :armed}
  def hit(_open), do: {:skip, :due}

  @spec tick(t) :: {:fire | :skip, t}
  def tick(:due), do: {:fire, :armed}
  def tick(_), do: {:skip, nil}
end
