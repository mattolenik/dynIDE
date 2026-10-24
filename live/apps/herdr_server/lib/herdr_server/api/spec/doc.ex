defmodule HerdrServer.Api.Spec.Doc do
  @moduledoc """
  Renders `HerdrServer.Api.Spec` as `docs/herdr-live/api.md`. Deterministic: no dates.
  """

  alias HerdrServer.Api.Spec

  # lib/herdr_server/api/spec -> repo root
  @path Path.expand("../../../../../../../docs/herdr-live/api.md", __DIR__)

  @error_docs %{
    parse_error: "The line was not valid JSON (the response `id` is `\"\"`).",
    invalid_request:
      "Valid JSON but not a request: no string `id`, no string `method`, or `params` not an object.",
    unknown_method: "No such method.",
    invalid_params: "Params failed validation; the message names the offending param.",
    not_found: "The workspace, tab or pane does not exist.",
    not_available: "The capability is not present (reload disabled, agent detection not built).",
    failed: "The request was valid but the operation could not be done.",
    timeout: "The operation did not finish in time.",
    backpressure: "The pane's input queue is full; retry.",
    events_lost: "The event stream could not keep up and was closed.",
    internal: "A handler crashed; the server is still running."
  }

  @spec path() :: String.t()
  def path, do: @path

  @spec markdown() :: String.t()
  def markdown do
    [header(), methods_section(), objects_section(), events_section()]
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp header do
    codes =
      Enum.map_join(Spec.error_codes(), "\n", &"| `#{&1}` | #{Map.fetch!(@error_docs, &1)} |")

    """
    # herdr-live socket API

    Generated from `HerdrServer.Api.Spec` by `mix herdr.api.docs`. Do not edit by hand.

    ## Transport

    - Unix domain socket at `$HERDR_LIVE_API`, else
      `${XDG_STATE_HOME:-~/.local/state}/herdr-live/api.sock` (an empty variable counts as unset).
    - Framing: one JSON object per line, UTF-8, at most 1 MiB per line. Several requests
      may be sent per connection; they are answered in order.
    - Request: `{"id": string, "method": string, "params": object?}`.
    - Success: `{"id": string, "result": {"type": string, ...}}`.
    - Error: `{"id": string, "error": {"code": string, "message": string, "data": object?}}`.
      For an unparseable line or a request without a string `id`, the response `id` is `""`.

    ## Ids

    - Workspace: `w<N>`, for example `w1`.
    - Tab: `w<N>:t<M>`, for example `w1:t2`.
    - Pane: `p<K>`, for example `p3`.

    Numbers are positive integers without leading zeros. Only this form is accepted.

    ## Errors

    | code | meaning |
    | --- | --- |
    #{codes}
    """
  end

  defp methods_section do
    Spec.methods()
    |> Enum.chunk_by(& &1.group)
    |> Enum.map_join("\n", fn [%{group: g} | _] = ms ->
      "## Methods: #{g}\n\n" <> Enum.map_join(ms, "\n", &method/1)
    end)
  end

  defp method(m) do
    """
    ### `#{m.name}`

    #{m.summary}

    #{cli(m)}#{params(m.params)}
    Result: #{result(m.result)}

    Errors: #{errors(m.errors)}
    """
  end

  defp cli(%{cli: nil}), do: ""
  defp cli(%{cli: cli}), do: "CLI: `#{cli}`\n\n"

  defp params([]), do: "Params: none.\n"

  defp params(ps) do
    rows =
      Enum.map_join(ps, "\n", fn p ->
        "| `#{p.name}` | #{type(p.type)}#{min_items(p)} | #{if p.required, do: "yes", else: "no"} | #{p.doc} |"
      end)

    "| param | type | required | description |\n| --- | --- | --- | --- |\n#{rows}\n"
  end

  defp min_items(%{min_items: n}), do: " (at least #{n})"
  defp min_items(_), do: ""

  defp result(name) do
    fields = Map.fetch!(Spec.results(), name)

    "`#{name}`" <>
      if(fields == [], do: " (no fields).", else: " with " <> field_list(fields) <> ".")
  end

  defp field_list(fields), do: Enum.map_join(fields, ", ", &"`#{&1.name}` (#{type(&1.type)})")

  defp errors([]), do: "none."
  defp errors(es), do: Enum.map_join(es, ", ", &"`#{&1}`")

  defp objects_section do
    body =
      Spec.objects()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, fields} ->
        rows = Enum.map_join(fields, "\n", &"| `#{&1.name}` | #{type(&1.type)} |")
        "### `#{name}`\n\n| field | type |\n| --- | --- |\n#{rows}\n"
      end)

    """
    ## Objects

    #{body}
    A layout `root` is `{"type": "pane", "pane_id": ...}` or
    `{"type": "split", "direction": "right" | "down", "ratio": number, "first": node, "second": node}`.
    """
  end

  defp events_section do
    list = Enum.map_join(Spec.event_types(), "\n", &"- `#{&1}`")
    "\n## Event types\n\n#{list}\n"
  end

  defp type(:string), do: "string"
  defp type(:boolean), do: "boolean"
  defp type(:integer), do: "integer"
  defp type(:object), do: "object"
  defp type(:null_or_string), do: "string or null"
  defp type(:pane_id), do: "pane id"
  defp type(:tab_id), do: "tab id"
  defp type(:workspace_id), do: "workspace id"
  defp type({:integer, a, b}), do: "integer #{a}..#{b}"
  defp type({:number, a, b}), do: "number #{a}..#{b}"
  defp type({:enum, vs}), do: Enum.map_join(vs, " | ", &"`#{&1}`")
  defp type({:list, t}), do: "list of " <> type(t)
  defp type({:map, :string}), do: "object of strings"
  defp type({:ref, name}), do: "`#{name}` object"
  defp type({:object, ps}), do: "object {" <> Enum.map_join(ps, ", ", &obj_param/1) <> "}"

  defp obj_param(p), do: "#{p.name}#{if p.required, do: "", else: "?"}: #{type(p.type)}"
end
