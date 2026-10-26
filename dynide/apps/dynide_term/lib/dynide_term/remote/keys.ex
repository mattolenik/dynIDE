defmodule DynideTerm.Remote.Keys do
  @moduledoc """
  Pane-mode (`terminal attach|observe`) detach keys, handled by the client itself (R17):
  `ctrl+b q` detaches, `ctrl+b ctrl+b` sends one `ctrl+b`, `ctrl+b <other key>` sends
  both. Only key presses and repeats count; any other event passes through and keeps a
  pending prefix. Pure.
  """

  alias DynideScene.Event

  @type state :: :idle | :prefix
  @type action :: :forward | {:forward, [Event.t()]} | :swallow | :detach

  @prefix Event.key("b", [:ctrl])

  @spec new() :: state
  def new, do: :idle

  @doc "`:forward` sends `event`, `{:forward, events}` sends `events` instead."
  @spec filter(state, Event.t()) :: {action, state}
  def filter(state, {:key, %{event: e}} = ev) when e in [:press, :repeat],
    do: key(state, strip(ev), ev)

  def filter(state, _ev), do: {:forward, state}

  defp key(:idle, @prefix, _ev), do: {:swallow, :prefix}
  defp key(:idle, _, _ev), do: {:forward, :idle}
  defp key(:prefix, @prefix, _ev), do: {:forward, :idle}
  defp key(:prefix, {:key, %{key: "q", mods: []}}, _ev), do: {:detach, :idle}
  defp key(:prefix, _, ev), do: {{:forward, [@prefix, ev]}, :idle}

  # compare on key and mods only
  defp strip({:key, %{key: k, mods: m}}), do: Event.key(k, m)
end
