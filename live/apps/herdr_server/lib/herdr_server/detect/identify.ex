defmodule HerdrServer.Detect.Identify do
  @moduledoc """
  Identifies the foreground agent from the processes of a pane's foreground job
  (`HerdrServer.Kernel.Pty.foreground_job/1`). Pure.

  Port of herdr's `lookup_agent` / `identify_agent_process_in_job`.

  ponytail: dropped herdr's Letta interactive-mode check, the Hermes installer
  bootstrap match, the Cursor bundled-node (Windows) match, cmd/powershell argv
  parsing and symlink canonicalisation of script paths; add when a real process
  needs them.
  """

  @labels ~w(pi claude codex gemini cursor devin agy cline omp mastracode opencode copilot
             kimi kiro droid amp grok hermes kilo qodercli qwen letta maki muse)

  # herdr `lookup_agent`: every accepted spelling of each canonical label.
  @aliases %{
    "claude-code" => "claude",
    "cursor-agent" => "cursor",
    "devin-cli" => "devin",
    "devin cli" => "devin",
    "antigravity" => "agy",
    "antigravity-cli" => "agy",
    ".cline" => "cline",
    "mastra-code" => "mastracode",
    "mastra code" => "mastracode",
    "opencode2" => "opencode",
    "open-code" => "opencode",
    "github-copilot" => "copilot",
    "ghcs" => "copilot",
    "kimi-code" => "kimi",
    "kimi code" => "kimi",
    "kiro-cli" => "kiro",
    "amp-local" => "amp",
    "grok-build" => "grok",
    "hermes-agent" => "hermes",
    "kilo-code" => "kilo",
    "kilo code" => "kilo",
    "qoderclicn" => "qodercli",
    "qoder" => "qodercli",
    "qodercn" => "qodercli",
    "qwen-code" => "qwen",
    "qwen code" => "qwen",
    "letta-code" => "letta",
    "letta code" => "letta",
    "muse-code" => "muse",
    "muse-cli" => "muse"
  }

  # Contiguous (normalised) path components of a script inside an installed package.
  @packages [
    {~w(node_modules @anthropic-ai claude-code), "claude"},
    {~w(node_modules @openai codex), "codex"},
    {~w(node_modules opencode-ai), "opencode"},
    {~w(node_modules @google gemini-cli), "gemini"},
    {~w(node_modules @earendil-works pi-coding-agent dist cli), "pi"},
    {~w(node_modules @earendil-works pi-coding-agent dist bundle cli), "pi"},
    {~w(node_modules @oh-my-pi pi-coding-agent dist cli), "omp"},
    {~w(node_modules @moonshot-ai kimi-code dist main.mjs), "kimi"},
    {~w(node_modules @qwen-code qwen-code dist index), "qwen"},
    {~w(node_modules mastracode dist cli), "mastracode"},
    {~w(node_modules @letta-ai letta-code letta), "letta"}
  ]

  @shells ~w(sh bash zsh fish)
  @runtimes ~w(node bun deno env npx bunx uv uvx)
  @generic @shells ++ @runtimes ++ ~w(python tmux)
  @value_options ~w(-r --require --loader --import --experimental-loader --inspect-port -W -X -S -L -o)

  @spec labels() :: [binary]
  def labels, do: @labels

  @doc "Canonical agent label for a process or executable name, or nil."
  @spec label(binary) :: binary | nil
  def label(name) when is_binary(name) do
    n = name |> normalize() |> basename()

    cond do
      n in @labels -> n
      is_map_key(@aliases, n) -> @aliases[n]
      muse_versioned?(n) -> "muse"
      true -> nil
    end
  end

  @doc "The agent running in a foreground job, as `{label, pid}`, or nil."
  @spec agent(map) :: {binary, pos_integer} | nil
  def agent(%{shell: true}), do: nil

  def agent(%{pgid: pgid, processes: processes}) do
    cands =
      for p <- processes, c = candidate(p), l = label(c), do: {p, c, l}

    case Enum.find(cands, fn {p, _, _} -> p.pid == pgid end) do
      {p, _, l} ->
        {l, p.pid}

      nil ->
        best(cands)
    end
  end

  # Enum.max_by keeps the first of equal priorities, like herdr.
  defp best([]), do: nil

  defp best(cands) do
    {p, _, l} = Enum.max_by(cands, fn {p, c, _} -> priority(p, c) end)
    {l, p.pid}
  end

  # herdr `normalized_process_name`: argv[0] over the OS name; generic runtimes
  # and shells resolve through their script argument.
  defp candidate(%{name: name} = p) do
    argv = Map.get(p, :argv) || []
    effective = List.first(argv) || name

    (generic?(effective) && wrapped(effective, argv)) ||
      (label(effective) && effective) ||
      path_token(effective) ||
      effective
  end

  defp wrapped(runtime, argv) do
    r = runtime |> basename() |> normalize()

    cond do
      python?(r) -> script_arg(argv, ["-c"], ["-m"])
      r in @shells -> script_arg(argv, ["-c"], [])
      r in @runtimes -> script_arg(argv, ["-e", "--eval", "-p", "--print"], [])
      true -> nil
    end
  end

  defp script_arg([_ | args], evals, modules), do: scan(args, evals, modules)
  defp script_arg([], _, _), do: nil

  defp scan([], _, _), do: nil
  defp scan(["--", tok | _], _, _), do: path_token(tok)
  defp scan(["--"], _, _), do: nil

  defp scan([arg | rest], evals, modules) do
    cond do
      flag?(arg, evals) or flag?(arg, modules) ->
        nil

      String.starts_with?(arg, "-") ->
        scan(if(arg in @value_options, do: Enum.drop(rest, 1), else: rest), evals, modules)

      true ->
        path_token(arg)
    end
  end

  defp flag?(arg, flags) do
    Enum.any?(flags, fn f ->
      arg == f or
        (not String.starts_with?(f, "--") and String.starts_with?(arg, f)) or
        (String.starts_with?(f, "--") and String.starts_with?(arg, f <> "="))
    end)
  end

  # Canonical label for a script path token: by basename, else by package path.
  defp path_token(token) do
    t = String.trim(token, "\"") |> String.trim("'")

    if t == "" or String.starts_with?(t, "-") do
      nil
    else
      label(basename(t)) || package_label(t)
    end
  end

  defp package_label(path) do
    comps = path |> String.split(["/", "\\"], trim: true) |> Enum.map(&normalize/1)

    Enum.find_value(@packages, fn {seq, l} ->
      n = length(seq)
      Enum.any?(Enum.chunk_every(comps, n, 1, :discard), &(&1 == seq)) && l
    end)
  end

  # herdr `process_priority`: a resolved wrapper beats a native binary beats a bare runtime.
  defp priority(p, cand) do
    cond do
      String.downcase(cand) != String.downcase(p.name) -> 3
      not generic?(cand) -> 2
      true -> 1
    end
  end

  defp generic?(name) do
    n = name |> basename() |> normalize()
    n in @generic or python?(n)
  end

  defp python?(n), do: Regex.match?(~r/\Apython(\d+(\.\d+)*)?\z/, n)

  # `muse-bin-<digit>...`: the launcher execs a versioned binary.
  defp muse_versioned?("muse-bin-" <> <<c, _::binary>>) when c in ?0..?9, do: true
  defp muse_versioned?(_), do: false

  defp basename(path), do: path |> String.split(["/", "\\"], trim: true) |> List.last() || path

  defp normalize(name) do
    n = name |> String.trim() |> String.downcase()

    Enum.find_value(~w(.exe .cmd .bat .ps1 .js), n, fn s ->
      String.ends_with?(n, s) && String.replace_suffix(n, s, "")
    end)
  end
end
