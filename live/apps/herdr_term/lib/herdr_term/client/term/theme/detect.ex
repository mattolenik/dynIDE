defmodule HerdrTerm.Client.Term.Theme.Detect do
  @moduledoc "Pure host light/dark detection: DSR scheme, OSC 11 background, COLORFGBG."

  @type appearance :: :dark | :light

  @doc "Appearance from the OSC 11 reply body, `rgb:RRRR/GGGG/BBBB` or `rgb:RR/GG/BB`."
  @spec from_osc11(binary) :: appearance | nil
  def from_osc11("rgb:" <> rest) do
    with [r, g, b] <- String.split(rest, "/"),
         {:ok, r} <- chan(r),
         {:ok, g} <- chan(g),
         {:ok, b} <- chan(b) do
      from_rgb({r, g, b})
    else
      _ -> nil
    end
  end

  def from_osc11(_), do: nil

  @doc "Light when 299R+587G+114B >= 128000 on 8-bit channels."
  @spec from_rgb({0..255, 0..255, 0..255} | term) :: appearance | nil
  def from_rgb({r, g, b}) when r in 0..255 and g in 0..255 and b in 0..255,
    do: if(299 * r + 587 * g + 114 * b >= 128_000, do: :light, else: :dark)

  def from_rgb(_), do: nil

  @doc """
  Appearance from a protocol caps map (`scheme`, else `colors.bg`), else the
  `COLORFGBG` value, else `:dark`.
  """
  @spec appearance(map | nil, binary | nil) :: appearance
  def appearance(caps, colorfgbg) do
    caps = caps || %{}

    caps[:scheme] || from_rgb(get_in(caps, [:colors, :bg])) || from_colorfgbg(colorfgbg) ||
      :dark
  end

  @doc "COLORFGBG `fg;bg` (or `fg;x;bg`): background index 7 or 15 is light."
  @spec from_colorfgbg(binary | nil) :: appearance | nil
  def from_colorfgbg(v) when is_binary(v) do
    case v |> String.split(";") |> List.last() |> Integer.parse() do
      {bg, ""} -> if bg in [7, 15], do: :light, else: :dark
      _ -> nil
    end
  end

  def from_colorfgbg(_), do: nil

  @spec from_dsr(term) :: appearance | nil
  def from_dsr(1), do: :dark
  def from_dsr(2), do: :light
  def from_dsr(_), do: nil

  # 1-4 hex digits scale to 8 bits
  defp chan(hex) when byte_size(hex) in 1..4 do
    case Integer.parse(hex, 16) do
      {v, ""} -> {:ok, div(v * 255 + div(max_for(hex), 2), max_for(hex))}
      _ -> :error
    end
  end

  defp chan(_), do: :error

  defp max_for(hex), do: Integer.pow(16, byte_size(hex)) - 1
end
