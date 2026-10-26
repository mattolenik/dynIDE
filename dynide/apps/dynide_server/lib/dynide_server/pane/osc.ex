defmodule DynideServer.Pane.Osc do
  @moduledoc """
  Pure parsing of the OSC payloads the kernel delivers raw (herdr's feed-path trackers,
  `src/pane/osc.rs` and `src/terminal/title.rs` at tag `herdr-reference`).

  Kernel events (`Kernel.Pty`): `{:title, id, raw}` (OSC 0/2), `{:pwd, id, raw}`
  (OSC 7) and `{:osc, id, code, payload | {:truncated, payload}}` for other codes, with
  `code;` already removed from the payload. `event/2` handles the `:osc` codes this
  server keeps: 9 (progress, or ConEmu cwd `9;9;<path>`), 1337 (`CurrentDir=`) and
  52 (clipboard set).
  """

  @title_max 256
  @clipboard_max 196_608
  @glyphs ~c"·✢✳✶✻✽◐◓◑◒"

  @type event :: {:cwd, binary} | {:progress, binary} | {:clipboard, binary} | :ignore

  @doc "A title as herdr keeps it: no C0/C1 controls or DEL, at most 256 chars, empty -> nil."
  @spec title(binary) :: binary | nil
  def title(raw) when is_binary(raw) do
    t =
      raw
      |> String.replace_invalid()
      |> String.to_charlist()
      |> Enum.reject(&control?/1)
      |> Enum.take(@title_max)
      |> List.to_string()

    if t == "", do: nil, else: t
  end

  defp control?(c), do: c < 0x20 or c in 0x7F..0x9F

  @doc """
  The title without one leading activity glyph (braille U+2800..U+28FF or one of
  `·✢✳✶✻✽◐◓◑◒`) when whitespace or the end follows it; trimmed, empty -> nil.
  """
  @spec stripped_title(binary | nil) :: binary | nil
  def stripped_title(nil), do: nil

  def stripped_title(t) do
    t = String.trim(t)

    stripped =
      case String.next_codepoint(t) do
        {<<c::utf8>>, rest} when (c in 0x2800..0x28FF or c in @glyphs) and rest == "" ->
          ""

        {<<c::utf8>>, <<_, _::binary>> = rest} when c in 0x2800..0x28FF or c in @glyphs ->
          if String.trim_leading(rest) != rest, do: String.trim(rest), else: t

        _ ->
          t
      end

    if stripped == "", do: nil, else: stripped
  end

  @doc """
  An absolute path from a reported cwd: a `file://` URI whose host is empty,
  `localhost` or this host (percent-decoded as UTF-8), or a bare or quoted path.
  """
  @spec cwd(binary) :: {:ok, binary} | :error
  def cwd(payload) do
    case String.trim(payload) do
      "file://" <> rest -> file_uri(rest)
      path -> absolute(String.trim(path, "\""))
    end
  end

  defp file_uri("/" <> _ = path), do: decode(path)

  defp file_uri(rest) do
    with [host, path] <- String.split(rest, "/", parts: 2),
         true <- local_host?(host),
         do: decode("/" <> path),
         else: (_ -> :error)
  end

  defp local_host?(host) do
    host = String.downcase(host)
    {:ok, me} = :inet.gethostname()
    host in ["", "localhost", String.downcase(List.to_string(me))]
  end

  defp decode(path) do
    case percent_decode(path, []) do
      {:ok, p} -> if String.valid?(p), do: absolute(p), else: :error
      :error -> :error
    end
  end

  # strict, like herdr: every `%` takes two hex digits
  defguardp hex?(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp percent_decode(<<?%, hi, lo, rest::binary>>, acc) when hex?(hi) and hex?(lo),
    do: percent_decode(rest, [acc, String.to_integer(<<hi, lo>>, 16)])

  defp percent_decode(<<?%, _::binary>>, _acc), do: :error
  defp percent_decode(<<c, rest::binary>>, acc), do: percent_decode(rest, [acc, c])
  defp percent_decode(<<>>, acc), do: {:ok, IO.iodata_to_binary(acc)}

  defp absolute("/" <> _ = path), do: {:ok, path}
  defp absolute(_), do: :error

  @doc "What an `{:osc, id, code, payload}` event means for the pane."
  @spec event(non_neg_integer, binary | {:truncated, binary}) :: event
  def event(_code, {:truncated, _}), do: :ignore
  def event(9, "9;" <> path), do: cwd_event(path)

  def event(9, payload) do
    case title(payload) do
      nil -> :ignore
      p -> {:progress, p}
    end
  end

  def event(1337, "CurrentDir=" <> path), do: cwd_event(path)
  def event(52, payload), do: clipboard(payload)
  def event(_code, _payload), do: :ignore

  defp cwd_event(path) do
    case cwd(path) do
      {:ok, p} -> {:cwd, p}
      :error -> :ignore
    end
  end

  # base64 of @clipboard_max bytes, padded
  @encoded_max div(@clipboard_max + 2, 3) * 4

  defp clipboard(payload) do
    with [sel, data] when sel in ["", "c"] and data not in ["", "?"] <-
           String.split(payload, ";", parts: 2),
         true <- byte_size(data) <= @encoded_max,
         {:ok, text} when text != "" and byte_size(text) <= @clipboard_max <-
           Base.decode64(data, padding: false) do
      {:clipboard, text}
    else
      _ -> :ignore
    end
  end
end
