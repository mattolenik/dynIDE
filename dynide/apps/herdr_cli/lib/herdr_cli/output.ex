defmodule HerdrCli.Output do
  @moduledoc """
  Pure rendering of API replies for the terminal: `{exit_code, stdout}` or
  `{exit_code, {:stderr, text}}`. JSON is one line with object keys sorted, so the
  same reply always prints the same bytes.

  herdr's shape (ruling R6, `src/cli.rs` `print_response`): a JSON verb prints the whole
  reply `{"id","result"}` on stdout; an error prints the whole reply `{"error","id"}` on
  stderr, exit 1. `:quiet` verbs (herdr's `Output::Quiet`) print nothing on success;
  `pane read` prints the text; `agent explain --json` prints the bare explain object.
  """

  @type rendered :: {0, binary()} | {1, {:stderr, binary()}}

  @doc "Encodes a decoded JSON term as one line of JSON (no newline), keys sorted."
  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary(:json.encode(term, &enc/2))

  defp enc(nil, _e), do: "null"
  defp enc(map, e) when is_map(map), do: :json.encode_key_value_list(Enum.sort(map), e)
  defp enc(other, e), do: :json.encode_value(other, e)

  @doc "Renders a reply for output mode `out`."
  @spec render(atom(), map()) :: rendered()
  def render(_out, %{"error" => error} = reply) when is_map(error),
    do: {1, {:stderr, encode(reply) <> "\n"}}

  def render(:json, %{"result" => result} = reply) when is_map(result),
    do: {0, encode(reply) <> "\n"}

  def render(out, %{"result" => result}) when is_map(result) do
    case body(out, result) do
      {:ok, text} -> {0, IO.iodata_to_binary(text)}
      :error -> unexpected(result)
    end
  end

  def render(_out, reply), do: unexpected(reply)

  defp body(:quiet, _r), do: {:ok, ""}
  defp body(:manifests, %{"manifests" => ms}) when is_list(ms), do: {:ok, manifests(ms)}
  defp body(:explain_json, %{"agent" => a}) when is_map(a), do: {:ok, [encode(a), ?\n]}
  defp body(:text, %{"text" => t}) when is_binary(t), do: {:ok, [t, ?\n]}
  defp body(:explain, %{"explanation" => t}) when is_binary(t), do: {:ok, t}
  defp body(:path, %{"path" => p}) when is_binary(p), do: {:ok, [p, ?\n]}
  defp body(:rollback, %{"batches" => []}), do: {:ok, "ok none\n"}

  defp body(:rollback, %{"batches" => ids}) when is_list(ids),
    do: {:ok, ["ok ", Enum.map_join(ids, " ", &scalar/1), ?\n]}

  defp body(:gate, %{"mode" => mode}) when is_binary(mode), do: {:ok, ["ok ", mode, ?\n]}

  defp body(:lines, r) do
    lines = for {k, v} <- Enum.sort(r), k != "type", do: [k, ?=, scalar(v), ?\n]
    {:ok, lines}
  end

  defp body(_out, _r), do: :error

  # herdr's print_agent_manifest_status (src/cli/server.rs): herdr-live has no remote
  # manifest channel, so the check fields print herdr's defaults ("never", "not checked",
  # remote "-"); a manifest that failed to load is herdr's "x" row with its error below
  defp manifests(ms) do
    rows =
      for m <- ms do
        marker = if m["error"], do: "x", else: " "

        row = [
          marker,
          " ",
          pad(m["agent"], 9),
          " ",
          pad(m["source"], 14),
          " active ",
          pad(m["version"], 14),
          " remote ",
          pad(nil, 14),
          " not checked\n"
        ]

        note = m["error"] || m["warning"]
        [row | if(note, do: ["  ", note, ?\n], else: [])]
      end

    ["last check: never\nresult: not checked\n\n" | rows]
  end

  defp pad(v, n), do: String.pad_trailing(v || "-", n)

  defp scalar(nil), do: ""
  defp scalar(v) when is_binary(v), do: v
  defp scalar(v), do: encode(v)

  defp unexpected(term),
    do: {1, {:stderr, "herdr-live: unexpected reply " <> encode(term) <> "\n"}}

  @doc "One event as one JSON line."
  @spec event(map()) :: binary()
  def event(map), do: encode(map) <> "\n"
end
