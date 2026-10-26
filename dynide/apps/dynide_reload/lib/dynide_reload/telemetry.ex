defmodule DynideReload.Telemetry do
  @moduledoc """
  Greppable one-line events for the log file:

      herdr-event <kind> ts=<unix ms> k=v k=v ...

  Values matching `^[A-Za-z0-9_.:/@+-]*$` are bare; anything else is double-quoted with
  `\\"` and `\\\\` escaped, newlines replaced by spaces, and cut to 300 bytes. Lists
  are comma-joined; module names lose the `Elixir.` prefix. The kinds and their keys
  are in the M7 telemetry table; this module only formats and logs.
  """

  require Logger

  @max_bytes 300

  @doc "The event line for `kind` and `fields` (pure apart from the timestamp)."
  @spec line(atom(), keyword()) :: String.t()
  def line(kind, fields) do
    ["herdr-event ", Atom.to_string(kind), " ts=", Integer.to_string(System.os_time(:millisecond))]
    |> Enum.concat(for {k, v} <- fields, do: [" ", Atom.to_string(k), "=", value(v)])
    |> IO.iodata_to_binary()
  end

  @doc "Logs `line/2` at info level."
  @spec event(atom(), keyword()) :: :ok
  def event(kind, fields), do: Logger.info(line(kind, fields))

  @doc """
  Maps a `DynideReload.Notices` event to `{kind, fields}`; `extra` is merged in (for
  example `compile_ms`, `failed`). Unknown events give `nil`.
  """
  @spec from_notice(term(), keyword()) :: {atom(), keyword()} | nil
  def from_notice({:loaded, id, mods}, extra),
    do: {:reload, [batch: id, fanout: length(mods), modules: mods] ++ extra}

  def from_notice({:rolled_back, id, mods, reason}, extra) do
    {:rollback,
     [
       batch: id,
       fanout: length(mods),
       modules: mods,
       reason: reason_class(reason),
       detail: reason_detail(reason)
     ] ++ extra}
  end

  def from_notice({:compile_error, [first | _] = diags}, extra) do
    {:compile_error,
     [
       file: Map.get(first, :file),
       line: line_of(Map.get(first, :position)),
       count: length(diags),
       msg: text(Map.get(first, :message))
     ] ++ extra}
  end

  def from_notice({:compile_error, []}, extra),
    do: {:compile_error, [file: nil, line: nil, count: 0, msg: ""] ++ extra}

  def from_notice({:rejected, mod, path}, extra),
    do: {:rejected, [module: mod, path: path] ++ extra}

  def from_notice({:purge_blocked, mod, holders}, extra),
    do: {:purge_blocked, [module: mod, holders: Enum.map(holders, &holder/1)] ++ extra}

  def from_notice({:synced, mods}, extra),
    do: {:sync, [count: length(mods), modules: mods, failed: 0] |> Keyword.merge(extra)}

  def from_notice({:tests, :running, _info}, _extra), do: nil

  def from_notice({:tests, result, info}, extra) do
    {:tests,
     [result: result, files: info[:files], failures: info[:failures], ms: info[:ms]] ++ extra}
  end

  def from_notice(_other, _extra), do: nil

  @classes [:raise, :throw, :exit, :timeout, :local_fun]

  defp reason_class(:manual), do: :manual
  defp reason_class({tag, _, _}) when tag in @classes, do: tag
  defp reason_class({inner, errors}) when is_list(errors), do: reason_class(inner)
  defp reason_class(_), do: :other

  defp reason_detail({tag, _, _} = failure) when tag in @classes,
    do: DynideReload.Guard.message(failure)

  defp reason_detail({inner, errors}) when is_list(errors),
    do: "#{reason_detail(inner)}; load errors: #{inspect(errors)}"

  defp reason_detail(other), do: inspect(other)

  defp line_of({l, _}) when is_integer(l), do: l
  defp line_of({l, _, _, _}) when is_integer(l), do: l
  defp line_of(l) when is_integer(l), do: l
  defp line_of(_), do: 0

  defp holder(%{pid: pid} = info), do: inspect(info[:name] || pid)
  defp holder(other), do: inspect(other)

  defp text(msg) when is_binary(msg), do: msg
  defp text(nil), do: ""
  defp text(msg), do: IO.iodata_to_binary(msg)

  # a list is bare when every element is: the commas joining them are not part of the value
  defp value(list) when is_list(list) do
    items = Enum.map(list, &scalar/1)
    if Enum.all?(items, &bare?/1), do: Enum.join(items, ","), else: items |> Enum.join(",") |> quoted()
  end

  defp value(v), do: v |> scalar() |> quote_if()

  defp scalar(nil), do: "none"
  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_integer(v), do: Integer.to_string(v)
  defp scalar(v) when is_atom(v), do: v |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp scalar(v), do: inspect(v)

  defp bare?(s), do: s =~ ~r/\A[A-Za-z0-9_.:\/@+-]*\z/

  defp quote_if(s), do: if(bare?(s), do: s, else: quoted(s))

  defp quoted(s) do
    escaped =
      s
      |> String.replace(["\r\n", "\n", "\r"], " ")
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{cut(escaped)}")
  end

  # at most @max_bytes, on a character boundary, never ending inside an escape pair
  defp cut(s) when byte_size(s) <= @max_bytes, do: s

  defp cut(s) do
    head = binary_part(s, 0, @max_bytes)
    head = trim_invalid(head)
    trailing = byte_size(head) - byte_size(String.trim_trailing(head, "\\"))
    if rem(trailing, 2) == 1, do: binary_part(head, 0, byte_size(head) - 1), else: head
  end

  defp trim_invalid(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_invalid(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
