defmodule DynideServer.Pane.KeyFallback do
  @moduledoc """
  herdr's legacy key fallbacks (reference `src/pane/input.rs`), applied before the vt
  encodes a key. Pure.

  Hyper and meta chords are never forwarded. A pane that negotiated nothing (kitty
  keyboard flags 0, modifyOtherKeys off) gets no super chords (no Cmd+C -> `c`) and
  the shell keys a legacy terminal sends: with `chord` = mods without alt (alt is kept
  throughout), enter with any chord is plain enter, ctrl+m enter, ctrl+i and ctrl+tab
  tab, ctrl+[ escape, and ctrl+shift+letter or ctrl+uppercase letter is ctrl+lowercase,
  translated again (ctrl+I -> tab). A translated key loses its `text`.
  """

  import Bitwise, only: [|||: 2]

  @spec translate(map, boolean) :: map | :drop
  def translate(%{mods: mods} = k, negotiated?) do
    cond do
      :hyper in mods or :meta in mods -> :drop
      negotiated? -> k
      :super in mods -> :drop
      true -> legacy(k, mods -- [:alt, :caps_lock, :num_lock], :alt in mods)
    end
  end

  defp legacy(%{key: :enter} = k, chord, alt?) when chord != [], do: to(k, :enter, [], alt?)
  defp legacy(%{key: "m"} = k, [:ctrl], alt?), do: to(k, :enter, [], alt?)
  defp legacy(%{key: key} = k, [:ctrl], alt?) when key in ["i", :tab], do: to(k, :tab, [], alt?)
  defp legacy(%{key: "["} = k, [:ctrl], alt?), do: to(k, :escape, [], alt?)

  defp legacy(%{key: <<c>>} = k, chord, alt?)
       when (chord == [:ctrl, :shift] and (c in ?a..?z or c in ?A..?Z)) or
              (chord == [:ctrl] and c in ?A..?Z) do
    k |> to(<<c ||| 0x20>>, [:ctrl], alt?) |> legacy([:ctrl], alt?)
  end

  defp legacy(k, _chord, _alt?), do: k

  defp to(k, key, mods, alt?) do
    mods = if alt?, do: Enum.sort([:alt | mods]), else: mods
    %{k | key: key, mods: mods, text: nil}
  end
end
