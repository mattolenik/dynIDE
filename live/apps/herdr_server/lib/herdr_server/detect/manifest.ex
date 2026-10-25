defmodule HerdrServer.Detect.Manifest do
  @moduledoc """
  One agent detection manifest: parse, validate and compile a TOML document.

  Pure. Ports herdr's `parse_manifest`, `validate_manifest` and `compile_gate`
  (src/detect/manifest.rs): unknown keys are rejected, limits and messages
  match herdr, and regexes compile under `:re` (PCRE2) with `[:unicode, :ucp, :dollar_endonly]`.
  """

  defmodule Gate do
    @moduledoc "A compiled matcher gate. `contains` is lowercased; regexes keep their source."
    defstruct all: [], any: [], not: [], contains: [], regex: [], line_regex: []

    @type t :: %__MODULE__{
            all: [t()],
            any: [t()],
            not: [t()],
            contains: [binary],
            regex: [{binary, :re.mp()}],
            line_regex: [{binary, :re.mp()}]
          }
  end

  defmodule Rule do
    @moduledoc "One manifest rule. `evidence` keeps the rule's raw top-level matchers for explain."
    defstruct [
      :id,
      :gate,
      :evidence,
      state: :unknown,
      priority: 0,
      region: "whole_recent",
      visible_idle: false,
      visible_blocker: false,
      visible_working: false,
      skip_state_update: false
    ]

    @type t :: %__MODULE__{
            id: binary,
            state: :idle | :working | :blocked | :unknown,
            priority: integer,
            region: binary,
            visible_idle: boolean,
            visible_blocker: boolean,
            visible_working: boolean,
            skip_state_update: boolean,
            gate: Gate.t(),
            evidence: map
          }
  end

  defstruct [:id, :version, :min_engine_version, aliases: [], rules: []]

  @type t :: %__MODULE__{
          id: binary,
          version: binary | nil,
          min_engine_version: non_neg_integer | nil,
          aliases: [binary],
          rules: [Rule.t()]
        }

  @manifest_keys ~w(id version min_engine_version updated_at aliases rules)
  @gate_keys ~w(all any not contains regex line_regex)
  @flag_keys ~w(visible_idle visible_blocker visible_working skip_state_update)
  @rule_keys ~w(id state priority region) ++ @flag_keys ++ @gate_keys
  @states %{"idle" => :idle, "working" => :working, "blocked" => :blocked, "unknown" => :unknown}
  @regions ~w(whole_recent after_last_prompt_marker before_current_prompt_marker
              whole_recent_without_current_prompt_marker current_prompt_block_marker
              after_current_prompt_block_marker prompt_box_body above_prompt_box
              last_non_empty_above_prompt_box after_last_horizontal_rule osc_title osc_progress)

  @max_rules 128
  @max_depth 8
  @max_gates 512
  @max_gate_matchers 32
  @max_matchers 1024
  @max_matcher_chars 512
  @top_lines_engine 3
  @max_top_lines 65_535

  @doc "Parses and validates a manifest, compiling every regex."
  @spec parse(binary) :: {:ok, t()} | {:error, binary}
  def parse(toml) when is_binary(toml) do
    with {:ok, doc} <- decode(toml),
         :ok <- known_keys(doc, @manifest_keys, "manifest"),
         {:ok, id} <- field(doc, "id", :string, :required, "manifest"),
         {:ok, version} <- field(doc, "version", :string, nil, "manifest"),
         {:ok, version} <- version(version),
         {:ok, min} <- field(doc, "min_engine_version", :u32, nil, "manifest"),
         {:ok, _} <- field(doc, "updated_at", :string, nil, "manifest"),
         {:ok, aliases} <- field(doc, "aliases", :strings, [], "manifest"),
         {:ok, rules} <- field(doc, "rules", :tables, [], "manifest"),
         {:ok, rules} <- rules(rules, min) do
      {:ok,
       %__MODULE__{
         id: id,
         version: version,
         min_engine_version: min,
         aliases: aliases,
         rules: rules
       }}
    end
  end

  @doc "Compiles one manifest regex under `:re`."
  #
  # Manifests are written for Rust `regex`, whose `\uXXXX` and `\u{X...}`
  # escapes PCRE2 rejects; they are rewritten to the equivalent `\x{...}`.
  # `\\` pairs are consumed first so an escaped backslash before `u` is kept.
  @spec compile_regex(binary) :: {:ok, :re.mp()} | {:error, binary}
  def compile_regex(src) do
    case :re.compile(pcre(src), [:unicode, :ucp, :dollar_endonly]) do
      {:ok, mp} -> {:ok, mp}
      {:error, {msg, pos}} -> {:error, "#{msg} at position #{pos}"}
    end
  end

  defp pcre(src) do
    Regex.replace(~r/\\\\|\\u\{([0-9A-Fa-f]+)\}|\\u([0-9A-Fa-f]{4})/, src, fn
      "\\\\", _, _ -> "\\\\"
      _, "", hex -> "\\x{#{hex}}"
      _, hex, _ -> "\\x{#{hex}}"
    end)
  end

  defp decode(toml) do
    case Toml.decode(toml) do
      {:ok, doc} -> {:ok, doc}
      {:error, {:invalid_toml, reason}} -> {:error, to_string(reason)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp version(nil), do: {:ok, nil}

  defp version(v) do
    v = String.trim(v)
    segments = String.split(v, ".")

    cond do
      v == "" ->
        {:error, "version must not be empty"}

      "" in segments ->
        {:error, "version #{inspect(v)} contains an empty segment"}

      not Enum.all?(segments, &(&1 =~ ~r/\A[0-9]+\z/)) ->
        {:error, "version #{inspect(v)} must be dotted numeric"}

      Enum.any?(segments, &(String.to_integer(&1) > 0xFFFF_FFFF_FFFF_FFFF)) ->
        {:error, "version #{inspect(v)} contains an oversized segment"}

      true ->
        {:ok, v}
    end
  end

  defp rules([], _min), do: {:error, "manifest must contain at least one rule"}

  defp rules(raw, _min) when length(raw) > @max_rules,
    do: {:error, "manifest contains #{length(raw)} rules, max is #{@max_rules}"}

  defp rules(raw, min) do
    raw
    |> Enum.with_index()
    |> map_reduce_ok(%{gates: 0, matchers: 0}, fn {r, i}, cx ->
      rule(r, "rules[#{i}]", min, cx)
    end)
    |> case do
      {:ok, rules, _cx} -> {:ok, rules}
      error -> error
    end
  end

  defp rule(raw, ctx, min, cx) do
    with :ok <- known_keys(raw, @rule_keys, ctx),
         {:ok, id} <- field(raw, "id", :string, :required, ctx),
         {:ok, state} <- field(raw, "state", :state, nil, ctx),
         {:ok, priority} <- field(raw, "priority", :i32, 0, ctx),
         {:ok, region} <- field(raw, "region", :string, "whole_recent", ctx),
         {:ok, flags} <- flags(raw, ctx),
         {:ok, gate} <- gate_shape(raw, ctx),
         region = String.trim(region),
         :ok <- check_rule(id, state, flags, region, min),
         {:ok, compiled, cx} <-
           gate(gate, "rule", 0, cx, :positive)
           |> prefix("rule #{id} has invalid matcher gates: ") do
      rule = %Rule{
        id: id,
        state: state || :unknown,
        priority: priority,
        region: region,
        gate: compiled,
        evidence: %{
          contains: gate.contains,
          regex: gate.regex,
          line_regex: gate.line_regex,
          all_count: length(gate.all),
          any_count: length(gate.any),
          not_count: length(gate.not)
        }
      }

      {:ok, struct!(rule, flags), cx}
    end
  end

  defp flags(raw, ctx) do
    Enum.reduce_while(@flag_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case field(raw, key, :bool, false, ctx) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), v)}}
        error -> {:halt, error}
      end
    end)
  end

  defp check_rule(id, state, flags, region, min) do
    cond do
      String.trim(id) == "" -> {:error, "manifest rule id must not be empty"}
      flags.skip_state_update -> check_skip(id, state, flags, region, min)
      true -> check_region(id, region, min)
    end
  end

  defp check_skip(id, state, flags, region, min) do
    cond do
      state != :unknown ->
        {:error, "rule #{id} uses skip_state_update without state = \"unknown\""}

      flags.visible_idle or flags.visible_blocker or flags.visible_working ->
        {:error, "rule #{id} uses skip_state_update with visible state evidence"}

      true ->
        check_region(id, region, min)
    end
  end

  defp check_region(id, region, min) do
    cond do
      not region?(region) ->
        {:error, "rule #{id} uses invalid region: #{region}"}

      String.starts_with?(region, "top_non_empty_lines(") and is_integer(min) and
          min < @top_lines_engine ->
        {:error,
         "rule #{id} uses top_non_empty_lines but min_engine_version is below #{@top_lines_engine}"}

      true ->
        :ok
    end
  end

  defp region?(r) do
    r in @regions or r =~ ~r/\A(bottom_lines|bottom_non_empty_lines)\(\d+\)\z/ or
      case Regex.run(~r/\Atop_non_empty_lines\(([1-9]\d*)\)\z/, r) do
        [_, n] -> String.to_integer(n) <= @max_top_lines
        nil -> false
      end
  end

  # Raw gate fields with nested gates shape-checked; validation happens in gate/5.
  defp gate_shape(raw, ctx) do
    with {:ok, contains} <- field(raw, "contains", :strings, [], ctx),
         {:ok, regex} <- field(raw, "regex", :strings, [], ctx),
         {:ok, line_regex} <- field(raw, "line_regex", :strings, [], ctx),
         {:ok, all} <- nested_shapes(raw, "all", ctx),
         {:ok, any} <- nested_shapes(raw, "any", ctx),
         {:ok, nots} <- nested_shapes(raw, "not", ctx) do
      {:ok,
       %{all: all, any: any, not: nots, contains: contains, regex: regex, line_regex: line_regex}}
    end
  end

  defp nested_shapes(raw, key, ctx) do
    with {:ok, tables} <- field(raw, key, :tables, [], ctx) do
      tables
      |> Enum.with_index()
      |> map_reduce_ok(nil, fn {t, i}, nil -> nested_shape(t, "#{ctx}.#{key}[#{i}]") end)
      |> case do
        {:ok, gates, nil} -> {:ok, gates}
        error -> error
      end
    end
  end

  defp nested_shape(table, ctx) do
    with :ok <- known_keys(table, @gate_keys, ctx),
         {:ok, g} <- gate_shape(table, ctx),
         do: {:ok, g, nil}
  end

  # herdr validate_gate (kind :positive) and validate_not_gate (kind :not), compiling as it goes.
  defp gate(g, ctx, depth, cx, kind) do
    label = if kind == :not, do: "not gate", else: ctx
    sub = if kind == :not, do: "not ", else: ""

    with :ok <- depth(depth, label),
         {:ok, cx} <- count_gate(cx),
         {:ok, cx} <- matcher_limits(g, label, cx),
         :ok <- has_matcher(g, label, kind),
         {:ok, regex} <- compile_all(g.regex, label, "regex"),
         {:ok, line_regex} <- compile_all(g.line_regex, label, "line_regex"),
         {:ok, all, cx} <-
           map_reduce_ok(g.all, cx, &gate(&1, sub <> "all gate", depth + 1, &2, :positive)),
         {:ok, any, cx} <-
           map_reduce_ok(g.any, cx, &gate(&1, sub <> "any gate", depth + 1, &2, :positive)),
         {:ok, nots, cx} <- map_reduce_ok(g.not, cx, &not_gate(&1, label, kind, depth + 1, &2)) do
      gate = %Gate{
        all: all,
        any: any,
        not: nots,
        contains: Enum.map(g.contains, &String.downcase/1),
        regex: regex,
        line_regex: line_regex
      }

      {:ok, gate, cx}
    end
  end

  defp not_gate(g, label, :positive, depth, cx) do
    if any_matcher?(g),
      do: gate(g, "not gate", depth, cx, :not),
      else: {:error, "#{label} contains an empty not gate"}
  end

  defp not_gate(g, _label, :not, depth, cx), do: gate(g, "not gate", depth, cx, :not)

  defp depth(depth, label) when depth > @max_depth,
    do: {:error, "#{label} exceeds max gate depth #{@max_depth}"}

  defp depth(_, _), do: :ok

  defp count_gate(%{gates: n}) when n + 1 > @max_gates,
    do: {:error, "manifest exceeds max gate count #{@max_gates}"}

  defp count_gate(cx), do: {:ok, %{cx | gates: cx.gates + 1}}

  defp matcher_limits(g, label, cx) do
    matchers = g.contains ++ g.regex ++ g.line_regex
    n = length(matchers)

    cond do
      n > @max_gate_matchers ->
        {:error, "#{label} has #{n} direct matchers, max is #{@max_gate_matchers}"}

      cx.matchers + n > @max_matchers ->
        {:error, "manifest exceeds max matcher count #{@max_matchers}"}

      Enum.any?(matchers, &(length(String.codepoints(&1)) > @max_matcher_chars)) ->
        {:error, "#{label} matcher exceeds max length #{@max_matcher_chars}"}

      true ->
        {:ok, %{cx | matchers: cx.matchers + n}}
    end
  end

  defp has_matcher(g, label, :positive),
    do:
      if(positive_matcher?(g),
        do: :ok,
        else: {:error, "#{label} must contain a positive matcher"}
      )

  defp has_matcher(g, _label, :not),
    do: if(any_matcher?(g), do: :ok, else: {:error, "not gate must contain a matcher"})

  defp positive_matcher?(g),
    do: Enum.any?([g.contains, g.regex, g.line_regex, g.all, g.any], &(&1 != []))

  defp any_matcher?(g), do: positive_matcher?(g) or g.not != []

  defp compile_all(patterns, label, field) do
    patterns
    |> map_reduce_ok(nil, fn src, nil ->
      case compile_regex(src) do
        {:ok, mp} ->
          {:ok, {src, mp}, nil}

        {:error, reason} ->
          {:error, "#{label} contains invalid #{field} pattern #{inspect(src)}: #{reason}"}
      end
    end)
    |> case do
      {:ok, compiled, nil} -> {:ok, compiled}
      error -> error
    end
  end

  defp prefix({:error, msg}, prefix), do: {:error, prefix <> msg}
  defp prefix(ok, _prefix), do: ok

  defp known_keys(map, allowed, ctx) do
    case Map.keys(map) -- allowed do
      [] ->
        :ok

      [key | _] ->
        {:error, "#{ctx}: unknown field `#{key}`, expected one of #{Enum.join(allowed, ", ")}"}
    end
  end

  defp field(map, key, type, default, ctx) do
    case Map.fetch(map, key) do
      :error when default == :required -> {:error, "#{ctx}: missing field `#{key}`"}
      :error -> {:ok, default}
      {:ok, value} -> typed(type, value, "#{ctx}: field `#{key}`")
    end
  end

  defp typed(:string, v, _) when is_binary(v), do: {:ok, v}
  defp typed(:bool, v, _) when is_boolean(v), do: {:ok, v}
  defp typed(:i32, v, _) when is_integer(v) and v in -0x8000_0000..0x7FFF_FFFF, do: {:ok, v}
  defp typed(:u32, v, _) when is_integer(v) and v in 0..0xFFFF_FFFF, do: {:ok, v}

  defp typed(:state, v, at) when is_binary(v) do
    case @states do
      %{^v => state} ->
        {:ok, state}

      _ ->
        {:error, "#{at}: unknown variant `#{v}`, expected one of idle, working, blocked, unknown"}
    end
  end

  defp typed(:strings, v, at) when is_list(v),
    do:
      if(Enum.all?(v, &is_binary/1),
        do: {:ok, v},
        else: {:error, "#{at} must be an array of strings"}
      )

  defp typed(:tables, v, at) when is_list(v),
    do:
      if(Enum.all?(v, &is_map/1),
        do: {:ok, v},
        else: {:error, "#{at} must be an array of tables"}
      )

  defp typed(type, v, at), do: {:error, "#{at}: invalid value #{inspect(v)}, expected #{type}"}

  defp map_reduce_ok(list, acc, fun) do
    Enum.reduce_while(list, {:ok, [], acc}, fn x, {:ok, out, acc} ->
      case fun.(x, acc) do
        {:ok, y, acc} -> {:cont, {:ok, [y | out], acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, out, acc} -> {:ok, Enum.reverse(out), acc}
      error -> error
    end
  end
end
