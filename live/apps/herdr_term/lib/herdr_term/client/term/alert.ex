defmodule HerdrTerm.Client.Term.Alert do
  @moduledoc """
  Pure: what this terminal does for a protocol `{:alert, a}`, given the scene root's
  props (`toast: %{delivery}`, `sound: %{enabled}`; missing ones are herdr's
  defaults, `:herdr` and enabled).

    * `delivery: :terminal` and a title: `{:osc9, "<title>: <body>"}`, control
      characters stripped, at most 200 characters. `:herdr` toasts come in the scene;
      `:off` shows nothing; `:system` (an OS notifier) is a recorded gap.
    * A sound when enabled: `{:sound, "done" | "request"}` (`Render` runs the sound
      command with it, else writes BEL).
  """

  @max 200

  @type action :: {:osc9, binary} | {:sound, binary}

  @spec actions(map, map) :: [action]
  def actions(alert, props) do
    delivery = get_in(props, [:toast, :delivery]) || :herdr
    sound = Map.get(props, :sound) || %{}
    osc(delivery, alert) ++ sound(Map.get(sound, :enabled, true), alert.sound)
  end

  defp osc(:terminal, %{title: t} = a) when is_binary(t) do
    text = if a.body, do: t <> ": " <> a.body, else: t

    [
      {:osc9,
       text |> String.replace(~r/[\x00-\x1f\x7f\x{80}-\x{9f}]/u, "") |> String.slice(0, @max)}
    ]
  end

  defp osc(_delivery, _alert), do: []

  defp sound(true, s) when s in [:done, :request], do: [{:sound, Atom.to_string(s)}]
  defp sound(_enabled, _sound), do: []
end
