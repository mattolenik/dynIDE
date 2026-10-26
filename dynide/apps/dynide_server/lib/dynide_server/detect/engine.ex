defmodule DynideServer.Detect.Engine do
  @moduledoc """
  Evaluates a manifest entry against a pane snapshot.

  Pure. Ports herdr's `evaluate_loaded_manifest`, `compiled_gate_matches`,
  `fallback_explain` and `explain_to_json_value` (src/detect/manifest.rs) and
  the CLI's `print_agent_explain_text`. Every rule is evaluated in file order;
  the highest priority match wins, the first in file order on ties.

  Regexes run under PCRE match limits; a run that hits a limit counts as no
  match and increments `limit_hits`.
  """

  alias DynideServer.Detect.{Manifest, Manifests, Regions}

  defmodule Detection do
    @moduledoc "One detection result."
    defstruct state: :unknown,
              skip_state_update: false,
              visible_idle: false,
              visible_blocker: false,
              visible_working: false,
              rule: nil,
              limit_hits: 0

    @type t :: %__MODULE__{
            state: :idle | :working | :blocked | :unknown,
            skip_state_update: boolean,
            visible_idle: boolean,
            visible_blocker: boolean,
            visible_working: boolean,
            rule: binary | nil,
            limit_hits: non_neg_integer
          }
  end

  @run_opts [
    {:match_limit, 200_000},
    {:match_limit_recursion, 10_000},
    {:capture, :none},
    :report_errors
  ]
  @fallback "default_known_agent_idle_fallback"
  @preview_chars 240

  @spec detect(Manifests.entry() | nil, Regions.input()) :: Detection.t()
  def detect(entry, input) do
    {_evaluated, winner, hits} = evaluate(entry, input)

    case winner do
      nil -> %Detection{state: fallback_state(entry), limit_hits: hits}
      rule -> struct!(Detection, Map.put(matched(rule), :limit_hits, hits))
    end
  end

  @spec explain(binary, Manifests.entry() | nil, Regions.input()) :: map
  def explain(label, entry, input) do
    {evaluated, winner, hits} = evaluate(entry, input)

    base = %{
      "agent" => label,
      "state" => "unknown",
      "manifest_source" => source(entry),
      "manifest_version" => entry && entry.version,
      "matched_rule" => nil,
      "visible_idle" => false,
      "visible_blocker" => false,
      "visible_working" => false,
      "screen_detection_skipped" => false,
      "skip_state_update" => false,
      "skipped_update_reason" => nil,
      "fallback_reason" => nil,
      "warning" => warning(entry),
      "evaluated_rules" => Enum.map(evaluated, &evaluated_json/1),
      "limit_hits" => hits
    }

    case {entry, winner} do
      {nil, _} ->
        %{base | "fallback_reason" => "unknown_agent"}

      {_, nil} ->
        %{base | "state" => "idle", "fallback_reason" => @fallback}

      {_, rule} ->
        m = matched(rule)

        %{
          base
          | "state" => Atom.to_string(rule.state),
            "matched_rule" => %{
              "id" => rule.id,
              "priority" => rule.priority,
              "region" => rule.region,
              "state" => Atom.to_string(rule.state)
            },
            "visible_idle" => m.visible_idle,
            "visible_blocker" => m.visible_blocker,
            "visible_working" => m.visible_working,
            "skip_state_update" => rule.skip_state_update,
            "skipped_update_reason" => if(rule.skip_state_update, do: "matched_rule:#{rule.id}")
        }
    end
  end

  @doc "herdr's `agent explain` text output, one line per fact, newline-terminated."
  @spec explain_text(map, boolean) :: binary
  def explain_text(ex, verbose) do
    rule = ex["matched_rule"]

    head =
      [
        "agent: #{ex["agent"] || "unknown"}",
        "state: #{ex["state"] || "unknown"}",
        "manifest: #{ex["manifest_source"] || "none"} #{ex["manifest_version"] || "unknown"}"
      ] ++
        rule_lines(ex, rule) ++
        opt("fallback_reason", ex["fallback_reason"]) ++
        opt("screen_detection_skip_reason", ex["screen_detection_skip_reason"]) ++
        opt("skipped_update_reason", ex["skipped_update_reason"]) ++
        opt("warning", ex["warning"])

    lines = if verbose, do: head ++ verbose_lines(ex), else: head
    Enum.map_join(lines, &(&1 <> "\n"))
  end

  defp rule_lines(_ex, nil), do: ["rule: none"]

  defp rule_lines(ex, rule) do
    line = "rule: #{rule["id"]} (region=#{rule["region"]} priority=#{rule["priority"]})"

    case Enum.find(ex["evaluated_rules"], &(&1["id"] == rule["id"])) do
      %{"evidence" => %{"region_preview" => p}} when p != "" -> [line, "evidence: #{inspect(p)}"]
      _ -> [line]
    end
  end

  defp opt(_key, nil), do: []
  defp opt(key, value), do: ["#{key}: #{value}"]

  defp verbose_lines(ex) do
    visible =
      "visible: idle=#{ex["visible_idle"]} blocker=#{ex["visible_blocker"]} working=#{ex["visible_working"]}"

    rules =
      case ex["evaluated_rules"] do
        [] -> []
        rules -> ["evaluated_rules:" | Enum.flat_map(rules, &rule_verbose/1)]
      end

    [visible | rules]
  end

  defp rule_verbose(r) do
    e = r["evidence"]
    mark = if r["matched"], do: "✓", else: "✗"

    [
      "  #{mark} #{r["id"]} priority=#{r["priority"]} region=#{r["region"]} state=#{r["state"]}",
      "    matchers: contains=#{inspect(e["contains"])} regex=#{inspect(e["regex"])} " <>
        "line_regex=#{inspect(e["line_regex"])} all=#{e["all_count"]} any=#{e["any_count"]} " <>
        "not=#{e["not_count"]}",
      "    region: bytes=#{e["region_bytes"]} preview=#{inspect(e["region_preview"])}"
    ]
  end

  # {[{rule, matched?, region_text}], winner | nil, limit_hits}
  defp evaluate(%{manifest: %Manifest{rules: rules}}, input) do
    {evaluated, {winner, hits, _regions}} =
      Enum.map_reduce(rules, {nil, 0, %{}}, fn rule, {winner, hits, regions} ->
        {reg, regions} = region(regions, input, rule.region)
        {ok?, hits} = gate?(rule.gate, reg, hits)

        winner =
          if ok? and (winner == nil or rule.priority > winner.priority), do: rule, else: winner

        {{rule, ok?, reg.text}, {winner, hits, regions}}
      end)

    {evaluated, winner, hits}
  end

  defp evaluate(_entry, _input), do: {[], nil, 0}

  defp region(regions, input, spec) do
    case regions do
      %{^spec => reg} ->
        {reg, regions}

      _ ->
        text = Regions.region(input, spec)
        reg = %{text: text, lower: String.downcase(text), lines: Regions.lines(text)}
        {reg, Map.put(regions, spec, reg)}
    end
  end

  defp gate?(g, reg, hits) do
    with true <- Enum.all?(g.contains, &String.contains?(reg.lower, &1)),
         {true, hits} <- all(g.regex, hits, &run(&1, reg.text, &2)),
         {true, hits} <-
           all(g.line_regex, hits, fn re, h -> any(reg.lines, h, &run(re, &1, &2)) end),
         {true, hits} <- all(g.all, hits, &gate?(&1, reg, &2)),
         {true, hits} <-
           if(g.any == [], do: {true, hits}, else: any(g.any, hits, &gate?(&1, reg, &2))),
         {false, hits} <- any(g.not, hits, &gate?(&1, reg, &2)) do
      {true, hits}
    else
      false -> {false, hits}
      {_, hits} -> {false, hits}
    end
  end

  defp all(list, hits, fun) do
    Enum.reduce_while(list, {true, hits}, fn x, {true, h} ->
      case fun.(x, h) do
        {true, h} -> {:cont, {true, h}}
        {false, h} -> {:halt, {false, h}}
      end
    end)
  end

  defp any(list, hits, fun) do
    Enum.reduce_while(list, {false, hits}, fn x, {false, h} ->
      case fun.(x, h) do
        {true, h} -> {:halt, {true, h}}
        {false, h} -> {:cont, {false, h}}
      end
    end)
  end

  defp run({_src, mp}, text, hits) do
    case :re.run(text, mp, @run_opts) do
      :match -> {true, hits}
      :nomatch -> {false, hits}
      {:error, _limit} -> {false, hits + 1}
    end
  end

  defp matched(rule) do
    %{
      state: rule.state,
      rule: rule.id,
      skip_state_update: rule.skip_state_update,
      visible_idle: rule.visible_idle and rule.state == :idle,
      visible_blocker: rule.visible_blocker and rule.state == :blocked,
      visible_working: rule.visible_working and rule.state == :working
    }
  end

  defp fallback_state(nil), do: :unknown
  defp fallback_state(_entry), do: :idle

  defp source(nil), do: nil
  defp source(%{source: :bundled}), do: "bundled"
  defp source(%{source: :override, path: path}), do: path

  defp warning(nil), do: nil

  defp warning(entry) do
    case Enum.reject([entry.error, entry.warning], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  defp evaluated_json({rule, matched?, text}) do
    e = rule.evidence

    %{
      "id" => rule.id,
      "priority" => rule.priority,
      "region" => rule.region,
      "state" => Atom.to_string(rule.state),
      "matched" => matched?,
      "evidence" => %{
        "contains" => e.contains,
        "regex" => e.regex,
        "line_regex" => e.line_regex,
        "all_count" => e.all_count,
        "any_count" => e.any_count,
        "not_count" => e.not_count,
        "region_bytes" => byte_size(text),
        "region_preview" => preview(text)
      }
    }
  end

  # Counts codepoints, as Rust `chars()` does, not graphemes.
  defp preview(text) do
    {head, rest} = text |> String.codepoints() |> Enum.split(@preview_chars)
    if rest == [], do: text, else: Enum.join(head) <> "..."
  end
end
