defmodule HerdrServer.AgentResume do
  @moduledoc """
  Pure: an agent's resumable session (herdr's `agent_resume.rs`), as reported by
  `pane.report_agent_session` and kept in pane meta as `agent_session`:
  `nil | %{agent: binary, kind: :id | :path | :argv, value: binary | [binary]}`.

  `plan/1` turns it into the argv herdr runs for that agent; a restore with
  `session.resume_agents_on_restore` types `shell(argv) <> "\\r"` into the pane's new
  shell (`Persist.RestorePlan.resumes/2`). An id or path session is taken only from the
  agent's official source (`herdr:<agent>`, `herdr:antigravity_cli` for `agy`), as in
  herdr. A reported `resume_argv` is refused until the reporter can hold the pane (M11's
  claim); the `:argv` kind stays in the schema for then.
  """

  @max_args 64
  @max_argv_bytes 8192
  @max_id 512
  @max_path 4096

  @type session :: %{agent: binary, kind: :id | :path | :argv, value: binary | [binary]}

  # herdr's per-agent resume argv: the flags before the session value
  @flags %{
    "claude" => ["--resume"],
    "codex" => ["resume"],
    "devin" => ["--resume"],
    "droid" => ["--resume"],
    "kimi" => ["--session"],
    "mastracode" => ["--thread"],
    "pi" => ["--session"],
    "hermes" => ["--resume"],
    "opencode" => ["--session"],
    "qodercli" => ["--resume"],
    "qwen" => ["--resume"],
    "kilo" => ["--session"],
    "agy" => ["--conversation"],
    "grok" => ["--resume"]
  }
  @agents Map.keys(@flags) ++ ~w(copilot omp cursor letta)

  @doc "The resume argv for a session, or `:none` (unknown agent, wrong kind, invalid argv)."
  @spec plan(session | nil) :: {:ok, [binary]} | :none
  def plan(%{kind: :argv, value: argv}), do: checked(argv)

  def plan(%{agent: agent, kind: kind, value: v}) when kind in [:id, :path] and is_binary(v) do
    if kind == :id or agent in ~w(pi omp),
      do: agent |> argv(v) |> checked(),
      else: :none
  end

  def plan(_none), do: :none

  defp argv("copilot", v), do: ["copilot", "--resume=" <> v]
  # omp resumes with `--resume=<id prefix or path>`; it has no `--session`, unlike pi
  defp argv("omp", v), do: ["omp", "--resume=" <> v]
  defp argv("cursor", v), do: ["cursor-agent", "--resume", v]
  defp argv("letta", "default:" <> ""), do: nil
  defp argv("letta", "default:" <> a), do: ~w(letta --conversation default --agent) ++ [a]
  defp argv("letta", v), do: ["letta", "--conversation", v]

  defp argv(agent, v) do
    case @flags do
      %{^agent => flags} -> [agent | flags] ++ [v]
      _ -> nil
    end
  end

  # a planned argv is typed into a shell: it obeys the same rules as a reported one
  defp checked(argv),
    do: if(is_list(argv) and validate(argv) == :ok, do: {:ok, argv}, else: :none)

  @doc """
  A reported `resume_argv`: 1..#{@max_args} args, at most #{@max_argv_bytes} bytes in all,
  no control characters, no `'` or `\\` (POSIX and fish single quotes stay literal), and
  a first element of `[A-Za-z0-9_.-]` not starting with `-` (herdr's rules).
  """
  @spec validate([binary]) :: :ok | {:error, binary}
  def validate(argv) when is_list(argv) do
    cond do
      argv == [] ->
        {:error, "resume_argv must not be empty"}

      length(argv) > @max_args ->
        {:error, "resume_argv allows at most #{@max_args} arguments"}

      not Enum.all?(argv, &is_binary/1) ->
        {:error, "resume_argv must be strings"}

      bytes(argv) > @max_argv_bytes ->
        {:error, "resume_argv allows at most #{@max_argv_bytes} bytes"}

      Enum.any?(argv, &control?/1) ->
        {:error, "resume_argv must not contain control characters"}

      Enum.any?(argv, &String.contains?(&1, ["'", "\\"])) ->
        {:error, "resume_argv must not contain apostrophes or backslashes"}

      not Regex.match?(~r/^[A-Za-z0-9_.][A-Za-z0-9_.-]*$/, hd(argv)) ->
        {:error, "resume_argv must start with a plain command name, not a path"}

      true ->
        :ok
    end
  end

  def validate(_other), do: {:error, "resume_argv must be a list"}

  defp bytes(argv), do: argv |> Enum.map(&byte_size/1) |> Enum.sum()

  # Unicode Cc (C0, DEL, C1), like Rust's char::is_control; invalid UTF-8 counts too
  defp control?(s), do: not String.valid?(s) or Regex.match?(~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u, s)

  @doc "POSIX single-quoted words joined by spaces (`validate/1` rules out `'`)."
  @spec shell([binary]) :: binary
  def shell(argv), do: Enum.map_join(argv, " ", &"'#{&1}'")

  @doc """
  The session a `pane.report_agent_session` report names (atom-keyed params): `{:ok,
  session | nil}` or `{:error, message}`. nil (nothing resumable) clears the pane's.
  """
  @spec from_report(map) :: {:ok, session | nil} | {:error, binary}
  def from_report(%{source: source, agent: agent} = p) do
    agent = String.trim(agent)

    cond do
      agent == "" ->
        {:error, "agent must not be empty"}

      # ponytail: herdr records resume_argv only from the source holding the pane
      # (pane.report_agent); refused until M11 serves that claim, then validate/1 and kind :argv
      is_list(p[:resume_argv]) ->
        {:error,
         "resume_argv requires the reporter to hold the pane; " <>
           "report its state with pane.report_agent first"}

      true ->
        {:ok, ref(String.trim(source), agent, p[:agent_session_id], p[:agent_session_path])}
    end
  end

  # pi and omp prefer a session path, everyone else takes only an id
  defp ref(source, agent, id, path) do
    cond do
      not official?(source, agent) -> nil
      agent in ~w(pi omp) and path?(path) -> %{agent: agent, kind: :path, value: path}
      id?(id) -> %{agent: agent, kind: :id, value: id}
      true -> nil
    end
  end

  defp official?("herdr:antigravity_cli", "agy"), do: true
  defp official?("herdr:" <> agent, agent), do: agent in @agents and agent != "agy"
  defp official?(_source, _agent), do: false

  defp id?(v), do: is_binary(v) and v != "" and byte_size(v) <= @max_id and not control?(v)

  defp path?(v),
    do:
      is_binary(v) and v != "" and byte_size(v) <= @max_path and not control?(v) and
        Path.type(v) == :absolute

  @doc "Store command: sets (or clears, nil) pane `id`'s `agent_session`."
  @spec put(map, pos_integer, session | nil) :: {map, []}
  def put(app, id, session) do
    case app.session.panes do
      %{^id => meta} ->
        {put_in(app.session.panes[id], Map.put(meta, :agent_session, session)), []}

      _ ->
        {app, []}
    end
  end
end
