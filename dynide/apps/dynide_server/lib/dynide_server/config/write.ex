defmodule DynideServer.Config.Write do
  @moduledoc """
  In-place edits of the TOML config (herdr's `config/write.rs` behaviour): `upsert/3`
  sets `key = value` lines in one table and leaves every other line byte for byte.

    * `table` `[]` is the top level (the lines before the first table header); `["ui",
      "sound"]` is `[ui.sound]`.
    * An existing `key = ...` line in the table is replaced (a value that continues over
      several lines, a multi-line array, is replaced whole); a missing key is appended
      after the table's last non-blank line; a missing table is appended at the end of
      the file. A missing file and its directory are created. The file is replaced
      atomically (written beside it, then renamed, keeping its mode); a symlinked path
      is resolved first and its target replaced, so the link stays.
    * Values: strings, booleans, integers and string arrays.

  Ponytail: line-based, not a TOML parser. A key set through a dotted key or inline table
  in a parent table (`[ui]` `sound.enabled = ..`), a `\"\"\"` multi-line string value and
  a trailing comment on a replaced line are not preserved: the first two yield a
  duplicate key the next load reports; upgrade to a format-preserving TOML editor if
  that matters.
  """

  @type value :: binary | boolean | integer | [binary]

  @spec upsert(Path.t(), [binary], %{binary => value}) :: :ok | {:error, term}
  def upsert(path, table, kv) do
    path = resolve(path, 40)

    with {:ok, bin} <- read(path),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> ".tmp"

      with {:error, _} = err <- swap(tmp, path, edit(bin, table, kv)) do
        File.rm(tmp)
        err
      end
    end
  end

  # a symlinked config (dotfiles) is written at its target, so the link stays a link
  defp resolve(path, 0), do: path

  defp resolve(path, n) do
    case :file.read_link_all(path) do
      {:ok, to} -> resolve(Path.expand(IO.chardata_to_string(to), Path.dirname(path)), n - 1)
      {:error, _} -> path
    end
  end

  # the new file keeps the old one's mode (a 0600 config stays private)
  defp swap(tmp, path, bin) do
    with :ok <- File.write(tmp, bin),
         :ok <- keep_mode(tmp, File.stat(path)),
         do: File.rename(tmp, path)
  end

  defp keep_mode(tmp, {:ok, %File.Stat{mode: mode}}),
    do: File.chmod(tmp, Bitwise.band(mode, 0o7777))

  defp keep_mode(_tmp, _no_file), do: :ok

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, ""}
      other -> other
    end
  end

  @doc false
  # pure: the edited file contents
  @spec edit(binary, [binary], %{binary => value}) :: binary
  def edit(bin, table, kv) do
    lines = String.split(bin, ~r/(?<=\n)/, trim: true)
    {lines, missing} = replace(lines, table, Enum.sort(kv))
    insert(lines, table, missing) |> IO.iodata_to_binary()
  end

  # --- replace existing keys ---

  defp replace(lines, table, kv) do
    {out, {_current, _skip, missing}} =
      Enum.flat_map_reduce(lines, {[], 0, kv}, &step(&1, &2, table))

    {out, missing}
  end

  # the state: the current table, open brackets of a replaced value, the keys still to set
  defp step(line, {cur, skip, missing}, _table) when skip > 0,
    do: {[], {cur, skip + depth(line), missing}}

  defp step(line, {cur, 0, missing}, table) do
    case {header(line), cur == table && key_of(line, missing)} do
      {nil, k} when is_binary(k) ->
        {{_, v}, missing} = List.keytake(missing, k, 0)
        {[assign(k, v, eol(line))], {cur, depth(value_part(line)), missing}}

      {nil, _} ->
        {[line], {cur, 0, missing}}

      {h, _} ->
        {[line], {h, 0, missing}}
    end
  end

  # [a.b] -> ["a", "b"]; [[a.b]] (an array of tables, never a write target) ->
  # {:array, ["a", "b"]}; nil for any other line
  defp header(line) do
    line = String.trim_trailing(line)

    cond do
      m = Regex.run(~r/^\s*\[\[([^\[\]]+)\]\]\s*(#.*)?$/, line) -> {:array, path(Enum.at(m, 1))}
      m = Regex.run(~r/^\s*\[([^\[\]]+)\]\s*(#.*)?$/, line) -> path(Enum.at(m, 1))
      true -> nil
    end
  end

  defp path(name), do: name |> String.split(".") |> Enum.map(&unquote_key/1)

  defp key_of(line, missing) do
    with [_, k] <- Regex.run(~r/^\s*("[^"]*"|'[^']*'|[A-Za-z0-9_-]+)\s*=/, line),
         k = unquote_key(k),
         true <- List.keymember?(missing, k, 0) do
      k
    else
      _ -> nil
    end
  end

  defp unquote_key(k), do: k |> String.trim() |> String.trim("\"") |> String.trim("'")

  defp value_part(line), do: line |> String.split("=", parts: 2) |> List.last()

  # open brackets left after `text`, outside strings and comments
  defp depth(text), do: depth(text, 0, nil)
  defp depth(<<>>, d, _q), do: d
  defp depth(<<"\\", _, rest::binary>>, d, ?"), do: depth(rest, d, ?")
  defp depth(<<q, rest::binary>>, d, q), do: depth(rest, d, nil)
  defp depth(<<q, rest::binary>>, d, nil) when q in [?", ?'], do: depth(rest, d, q)
  defp depth(<<"#", _::binary>>, d, nil), do: d
  defp depth(<<"[", rest::binary>>, d, nil), do: depth(rest, d + 1, nil)
  defp depth(<<"]", rest::binary>>, d, nil), do: depth(rest, d - 1, nil)
  defp depth(<<_, rest::binary>>, d, q), do: depth(rest, d, q)

  defp eol(line), do: if(String.ends_with?(line, "\r\n"), do: "\r\n", else: "\n")

  # --- insert missing keys ---

  defp insert(lines, _table, []), do: lines

  defp insert(lines, [], kv) do
    {top, rest} = Enum.split_while(lines, &(header(&1) == nil))
    {body, blanks} = split_trailing_blanks(top)
    new = assigns(kv)
    gap = if rest != [] and blanks == [], do: ["\n"], else: []
    terminate(body) ++ new ++ gap ++ blanks ++ rest
  end

  defp insert(lines, table, kv) do
    case Enum.find_index(lines, &(header(&1) == table)) do
      nil ->
        sep = if lines == [], do: [], else: ["\n"]
        terminate(lines) ++ sep ++ ["[#{Enum.map_join(table, ".", &key/1)}]\n" | assigns(kv)]

      i ->
        {before, [h | after_h]} = Enum.split(lines, i)
        {section, rest} = Enum.split_while(after_h, &(header(&1) == nil))
        {body, blanks} = split_trailing_blanks(section)
        before ++ [h | terminate(body)] ++ assigns(kv) ++ blanks ++ rest
    end
  end

  defp split_trailing_blanks(lines) do
    {blanks, body} = lines |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
    {Enum.reverse(body), Enum.reverse(blanks)}
  end

  # a last line without its newline gets one before anything follows it
  defp terminate([]), do: []

  defp terminate(lines) do
    {init, [last]} = Enum.split(lines, -1)
    if String.ends_with?(last, "\n"), do: lines, else: init ++ [last <> "\n"]
  end

  defp assigns(kv), do: Enum.map(kv, fn {k, v} -> assign(k, v, "\n") end)

  # --- encoding ---

  defp assign(k, v, eol), do: IO.iodata_to_binary([key(k), " = ", encode(v), eol])

  defp key(k), do: if(k =~ ~r/^[A-Za-z0-9_-]+$/, do: k, else: string(k))

  defp encode(v) when is_boolean(v), do: to_string(v)
  defp encode(v) when is_integer(v), do: Integer.to_string(v)
  defp encode(v) when is_binary(v), do: string(v)
  defp encode(v) when is_list(v), do: ["[", Enum.map_intersperse(v, ", ", &string/1), "]"]

  defp string(s), do: "\"" <> for(<<c::utf8 <- s>>, into: "", do: esc(c)) <> "\""

  defp esc(?"), do: "\\\""
  defp esc(?\\), do: "\\\\"
  defp esc(?\n), do: "\\n"
  defp esc(?\t), do: "\\t"
  defp esc(?\r), do: "\\r"

  defp esc(c) when c < 0x20 or c == 0x7F,
    do: "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")

  defp esc(c), do: <<c::utf8>>
end
