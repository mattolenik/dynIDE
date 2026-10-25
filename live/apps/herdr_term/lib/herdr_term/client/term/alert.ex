defmodule HerdrTerm.Client.Term.Alert do
  @moduledoc """
  Pure: what this terminal does for a protocol `{:alert, a}`, given the scene root's
  props (`toast: %{delivery}`, `sound: %{enabled}`; missing ones are herdr's
  defaults, `:herdr` and enabled) and the client's environment (`Notify.backend/1`).

    * A title, control characters stripped from it and the body, each at most 200
      characters: `delivery: :terminal` is `{:write, bytes}` (`Notify.sequence/4`: OSC 9
      or OSC 99, tmux-wrapped under `TMUX`); `:system` is `{:system, title, body}`
      (`Render` calls the desktop notifier). `:herdr` toasts come in the scene; `:off`
      shows nothing.
    * A sound when enabled: `{:sound, :done | :request}` (`Render` runs the sound
      command, else plays the sound file, else writes BEL).
  """

  alias HerdrTerm.Client.Term.Notify

  @max 200

  @type action :: {:write, binary} | {:system, binary, binary | nil} | {:sound, atom}

  @spec actions(map, map, %{optional(binary) => binary}) :: [action]
  def actions(alert, props, env \\ %{}) do
    delivery = get_in(props, [:toast, :delivery]) || :herdr
    sound = Map.get(props, :sound) || %{}
    notify(delivery, alert, env) ++ sound(Map.get(sound, :enabled, true), alert.sound)
  end

  defp notify(:terminal, %{title: t} = a, env) when is_binary(t),
    do: [
      {:write, Notify.sequence(Notify.backend(env), clean(t), clean(a.body), Notify.tmux?(env))}
    ]

  defp notify(:system, %{title: t} = a, _env) when is_binary(t),
    do: [{:system, clean(t), clean(a.body)}]

  defp notify(_delivery, _alert, _env), do: []

  defp clean(nil), do: nil

  defp clean(text),
    do: text |> String.replace(~r/[\x00-\x1f\x7f\x{80}-\x{9f}]/u, "") |> String.slice(0, @max)

  defp sound(true, s) when s in [:done, :request], do: [{:sound, s}]
  defp sound(_enabled, _sound), do: []
end
