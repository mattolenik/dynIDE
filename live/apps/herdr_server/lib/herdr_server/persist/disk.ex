defmodule HerdrServer.Persist.Disk do
  @moduledoc """
  Snapshot and scrollback files for session persistence.

  Files: `<dir>/session.<name>.etf` (the snapshot envelope
  `%{format: :herdr_live_session, v, saved_at, snapshot}`) and
  `<dir>/session.<name>.scrollback/<pane_id>.etf`
  (`%{format: :herdr_live_scrollback, v: 1, cols, bytes}`). Every write is atomic (temp
  file in the same dir, `:file.sync`, rename), files are 0600 and directories this
  module creates are 0700. Reads use `binary_to_term(.., [:safe])`.

  A snapshot file that does not decode is renamed aside (`.bad-<ms>`, or `.v<N>-<ms>`
  for a newer schema version) so the next start begins fresh; the 5 newest moved-aside
  files of a session name are kept.

  `config/0` is `config :herdr_server, HerdrServer.Persist` over the defaults, with
  `dir` and `name` resolved from the raw values `runtime.exs` sets.
  """

  require Logger

  alias HerdrServer.Handoff.Link
  alias HerdrServer.Persist.Schema

  @defaults %{
    enabled: false,
    dir: nil,
    name: nil,
    poll_ms: 1000,
    scrollback_ms: 60_000,
    scrollback_rows: 1000
  }
  @name_re ~r/^[A-Za-z0-9_.-]{1,64}$/
  @keep_aside 5
  @scrollback_v 1

  @type cfg :: %{required(:dir) => binary, required(:name) => binary, optional(atom) => term}

  @doc "The persist config with defaults, `dir` and `name` resolved."
  @spec config() :: map
  def config do
    raw =
      Map.merge(@defaults, Map.new(Application.get_env(:herdr_server, HerdrServer.Persist, [])))

    env = System.get_env() |> Map.take(["XDG_STATE_HOME", "HOME"])
    dir = resolve_dir(Map.put(env, "HERDR_LIVE_STATE_DIR", raw.dir))
    %{raw | dir: dir, name: resolve_name(raw.name)}
  end

  @doc """
  The state dir from an env map: `HERDR_LIVE_STATE_DIR`, else
  `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live`. Empty values count as unset.
  """
  @spec resolve_dir(%{optional(binary) => binary | nil}) :: binary
  def resolve_dir(env) do
    cond do
      set?(env["HERDR_LIVE_STATE_DIR"]) -> env["HERDR_LIVE_STATE_DIR"]
      set?(env["XDG_STATE_HOME"]) -> Path.join(env["XDG_STATE_HOME"], "herdr-live")
      true -> Path.join([env["HOME"] || "", ".local", "state", "herdr-live"])
    end
  end

  defp set?(v), do: is_binary(v) and v != ""

  @doc "The session name: `value` when it matches `#{inspect(@name_re.source)}`, else `default`."
  @spec resolve_name(binary | nil) :: binary
  def resolve_name(value) when value in [nil, ""], do: "default"

  def resolve_name(value) do
    if is_binary(value) and Regex.match?(@name_re, value) do
      value
    else
      Logger.warning("HERDR_LIVE_SESSION #{inspect(value)} is not a valid name; using default")
      "default"
    end
  end

  @spec session_path(cfg) :: binary
  def session_path(cfg), do: Path.join(cfg.dir, "session.#{cfg.name}.etf")

  @spec scrollback_dir(cfg) :: binary
  def scrollback_dir(cfg), do: Path.join(cfg.dir, "session.#{cfg.name}.scrollback")

  # --- snapshot ---

  @doc "Writes `snapshot` atomically; refuses a snapshot that is not `Schema.plain?/1`."
  @spec write(cfg, Schema.snapshot()) :: :ok | {:error, term}
  def write(cfg, snapshot) do
    if Schema.plain?(snapshot) do
      envelope = %{
        format: :herdr_live_session,
        v: Schema.version(),
        saved_at: System.os_time(:millisecond),
        snapshot: snapshot
      }

      atomic_write(session_path(cfg), encode(envelope))
    else
      {:error, :not_plain}
    end
  end

  @doc """
  Reads the snapshot. `:none` when there is no file; a file that does not decode is
  moved aside and gives `{:error, reason}`.
  """
  @spec read(cfg) :: {:ok, Schema.snapshot(), integer} | :none | {:error, term}
  def read(cfg) do
    path = session_path(cfg)

    case File.read(path) do
      {:ok, bin} ->
        case bin |> decode() |> session() do
          {:ok, snap, saved_at} -> {:ok, snap, saved_at}
          {:error, reason} -> quarantine(cfg, path, reason)
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session({:ok, %{format: :herdr_live_session, v: v} = env}) when is_integer(v) do
    s = Map.get(env, :snapshot)
    at = Map.get(env, :saved_at)

    cond do
      v > Schema.version() -> {:error, {:newer_version, v}}
      v < 1 or not is_integer(at) or not is_map(s) -> {:error, :bad_envelope}
      not Schema.plain?(s) -> {:error, :not_plain}
      true -> {:ok, s, at}
    end
  end

  defp session({:ok, _other}), do: {:error, :bad_envelope}
  defp session({:error, _} = err), do: err

  defp quarantine(cfg, path, reason) do
    tag =
      case reason do
        {:newer_version, v} -> "v#{v}"
        _ -> "bad"
      end

    to = aside_path(path, tag, System.os_time(:millisecond))
    moved = File.rename(path, to)
    prune_aside(cfg)

    HerdrReload.Telemetry.event(:persist_error,
      op: :read,
      reason: inspect(reason),
      moved: if(moved == :ok, do: Path.basename(to), else: inspect(moved))
    )

    {:error, reason}
  end

  # a free name: bumps the ms suffix on a collision so the order stays strict
  defp aside_path(path, tag, ms) do
    to = "#{path}.#{tag}-#{ms}"
    if File.exists?(to), do: aside_path(path, tag, ms + 1), else: to
  end

  defp prune_aside(cfg) do
    re = ~r/^session\.#{Regex.escape(cfg.name)}\.etf\.(?:bad|v\d+)-(\d+)$/

    case File.ls(cfg.dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&aside_entry(re, &1))
        |> Enum.sort(:desc)
        |> Enum.drop(@keep_aside)
        |> Enum.each(fn {_, n} -> File.rm(Path.join(cfg.dir, n)) end)

      {:error, _} ->
        :ok
    end
  end

  defp aside_entry(re, name) do
    case Regex.run(re, name) do
      [_, ms] -> [{String.to_integer(ms), name}]
      nil -> []
    end
  end

  # --- scrollback ---

  @doc """
  Writes pane `id`'s scrollback bytes (rendered at `cols`) atomically. Ids come from a
  snapshot on disk: anything but a positive integer is `{:error, :bad_id}`.
  """
  @spec write_scrollback(cfg, pos_integer, binary, pos_integer) :: :ok | {:error, term}
  def write_scrollback(cfg, id, bytes, cols)
      when is_integer(id) and id > 0 and is_binary(bytes) and is_integer(cols) do
    envelope = %{format: :herdr_live_scrollback, v: @scrollback_v, cols: cols, bytes: bytes}
    atomic_write(scrollback_path(cfg, id), encode(envelope))
  end

  def write_scrollback(_cfg, _id, _bytes, _cols), do: {:error, :bad_id}

  @doc "Pane `id`'s scrollback bytes, or nil. A file that does not decode is deleted."
  @spec read_scrollback(cfg, pos_integer) :: binary | nil
  def read_scrollback(cfg, id) when is_integer(id) and id > 0 do
    path = scrollback_path(cfg, id)

    with {:ok, bin} <- File.read(path),
         {:ok, %{format: :herdr_live_scrollback, v: @scrollback_v, bytes: b}} when is_binary(b) <-
           decode(bin) do
      b
    else
      {:error, :enoent} ->
        nil

      _bad ->
        File.rm(path)
        nil
    end
  end

  def read_scrollback(_cfg, _id), do: nil

  @doc "Deletes every scrollback file except those of `keep_ids`."
  @spec prune_scrollback(cfg, [pos_integer]) :: :ok
  def prune_scrollback(cfg, keep_ids) do
    dir = scrollback_dir(cfg)
    keep = MapSet.new(keep_ids, &"#{&1}.etf")

    case File.ls(dir) do
      {:ok, names} ->
        for n <- names, not MapSet.member?(keep, n), do: File.rm(Path.join(dir, n))
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp scrollback_path(cfg, id) when is_integer(id) and id > 0,
    do: Path.join(scrollback_dir(cfg), "#{id}.etf")

  @doc "Removes stale snapshot temp files (`session.<name>.etf.tmp-*`) left by a crash."
  @spec sweep_tmp(cfg) :: :ok
  def sweep_tmp(cfg) do
    prefix = "session.#{cfg.name}.etf.tmp-"

    case File.ls(cfg.dir) do
      {:ok, names} ->
        for n <- names, String.starts_with?(n, prefix), do: File.rm(Path.join(cfg.dir, n))
        :ok

      {:error, _} ->
        :ok
    end
  end

  # --- encoding and files ---

  defp encode(term), do: :erlang.term_to_binary(term, [:compressed, {:minor_version, 2}])

  # [:safe] refuses atoms this VM does not know yet: load every module once, then retry
  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    ArgumentError ->
      Link.preload()

      try do
        {:ok, :erlang.binary_to_term(bin, [:safe])}
      rescue
        ArgumentError -> {:error, :bad_term}
      end
  end

  defp atomic_write(path, bin) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- ensure_dir(Path.dirname(path)),
         :ok <- write_synced(tmp, bin),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        File.rm(tmp)
        err
    end
  end

  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  defp write_synced(tmp, bin) do
    with {:ok, fd} <- :file.open(tmp, [:write, :exclusive, :binary, :raw]) do
      result =
        with :ok <- File.chmod(tmp, 0o600),
             :ok <- :file.write(fd, bin),
             do: :file.sync(fd)

      # a failed close is a failed write: the caller removes the temp
      case {result, :file.close(fd)} do
        {:ok, close} -> close
        {err, _} -> err
      end
    end
  end
end
