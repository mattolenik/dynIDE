defmodule HerdrServer.Plugins.Command do
  @moduledoc """
  Runs one argv (never through a shell) to completion: cwd, env, stdin from /dev/null,
  stdout and stderr captured apart and capped. Blocking; callers run it in their own process.
  """

  alias HerdrServer.Plugins.Paths

  @cap 65_536
  # ponytail: a sh wrapper sends stdout and stderr to files and, with job control, starts
  # the command as its own process group so a timeout kills the whole tree; a NIF if
  # Windows ever matters. The port carries only the wrapper, so the run ends when the
  # command exits even if a descendant still holds its output open (as herdr). The files
  # grow with the command's output until it exits (only the first `cap` bytes are read):
  # bounded by the timeout, if any. The wrapper's own stderr (job notices) goes to /dev/null.
  @wrapper ~S(d=$HERDR_LIVE_CMD_DIR; unset HERDR_LIVE_CMD_DIR; exec 2>/dev/null; set -m; ) <>
             ~S("$0" "$@" </dev/null >"$d/out" 2>"$d/err" & echo $! >"$d/pid"; wait $!)

  @type result :: %{
          exit_code: integer() | nil,
          stdout: binary(),
          stderr: binary(),
          error: binary() | nil
        }

  @doc """
  `env` is `[{name, value | nil}]` (nil unsets). Options: `:cap` bytes per stream (64 KiB;
  a cut stream ends with herdr's truncation marker),
  `:timeout_ms` (none) after which the OS process is killed, `:tmp_dir`, a private
  (0700) dir under which each run gets its own fresh dir for the output files (default
  `<state>/tmp`; plugin callers pass the plugin state dir).
  """
  @spec run([String.t()], Path.t(), [{String.t(), String.t() | nil}], keyword()) :: result()
  def run([cmd | args], cwd, env, opts) do
    case resolve(cmd, cwd) do
      nil -> %{exit_code: nil, stdout: "", stderr: "", error: "command not found: #{cmd}"}
      exe -> spawn_port(exe, args, cwd, env, opts)
    end
  end

  @doc "`cmd` as an executable: a path containing `/` against `cwd`, a bare name via PATH."
  @spec resolve(String.t(), Path.t()) :: Path.t() | nil
  def resolve(cmd, cwd) do
    if String.contains?(cmd, "/") do
      path = Path.expand(cmd, cwd)
      if File.regular?(path), do: path
    else
      System.find_executable(cmd)
    end
  end

  defp spawn_port(exe, args, cwd, env, opts) do
    cap = opts[:cap] || @cap

    case run_dir(opts[:tmp_dir] || Path.join(Paths.state_dir(), "tmp")) do
      {:ok, dir} ->
        try do
          port_run(exe, args, cwd, [{"HERDR_LIVE_CMD_DIR", dir} | env], dir, cap, opts)
        after
          File.rm_rf(dir)
        end

      {:error, e} ->
        %{exit_code: nil, stdout: "", stderr: "", error: "command dir: #{:file.format_error(e)}"}
    end
  end

  # a fresh dir (mkdir never follows a planted symlink) inside a 0700 base
  defp run_dir(base) do
    dir = Path.join(base, "cmd-" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))

    with :ok <- File.mkdir_p(base),
         :ok <- File.chmod(base, 0o700),
         :ok <- File.mkdir(dir),
         do: {:ok, dir}
  end

  defp port_run(exe, args, cwd, env, dir, cap, opts) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["-c", @wrapper, exe | args],
        cd: cwd,
        env: Enum.map(env, fn {k, v} -> {~c"#{k}", if(v, do: ~c"#{v}", else: false)} end)
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    deadline = opts[:timeout_ms] && System.monotonic_time(:millisecond) + opts[:timeout_ms]
    {code, error} = collect(port, {pid, dir}, deadline)
    out = head(Path.join(dir, "out"), cap)
    %{exit_code: code, stdout: out, stderr: head(Path.join(dir, "err"), cap), error: error}
  end

  # the wrapper writes nothing to the port: only its exit status matters
  defp collect(port, who, deadline) do
    left =
      if deadline, do: max(deadline - System.monotonic_time(:millisecond), 0), else: :infinity

    receive do
      {^port, {:data, _}} -> collect(port, who, deadline)
      {^port, {:exit_status, s}} -> {s, nil}
    after
      left ->
        kill(who)
        drain(port)
        {nil, "timed out"}
    end
  end

  # the command's process group (its pid, written by the wrapper) and the wrapper itself:
  # exactly what we started, never by name
  defp kill({sh, dir}) do
    targets =
      case File.read(Path.join(dir, "pid")) do
        {:ok, pid} -> ["--", "-" <> String.trim(pid), Integer.to_string(sh)]
        {:error, _} -> [Integer.to_string(sh)]
      end

    System.cmd("kill", ["-9" | targets], stderr_to_stdout: true)
  end

  # wait briefly for the exit status, then close the port and drop what it sent meanwhile
  defp drain(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 -> :ok
    end

    if Port.info(port), do: Port.close(port)
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp head(file, cap) do
    case File.open(file, [:read, :binary]) do
      {:ok, f} ->
        data = IO.binread(f, cap + 1)
        File.close(f)

        case data do
          data when is_binary(data) and byte_size(data) > cap ->
            binary_part(data, 0, cap) <> "\n[herdr truncated plugin output after #{cap} bytes]"

          data when is_binary(data) ->
            data

          _ ->
            ""
        end

      {:error, _} ->
        ""
    end
  end
end
