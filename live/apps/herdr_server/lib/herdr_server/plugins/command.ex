defmodule HerdrServer.Plugins.Command do
  @moduledoc """
  Runs one argv (never through a shell) to completion: cwd, env, stdin from /dev/null,
  stdout and stderr captured apart and capped. Blocking; callers run it in their own process.
  """

  @cap 65_536
  # ponytail: a sh wrapper sends stderr to a tmp file (ports have one output stream);
  # a NIF if Windows ever matters
  @wrapper ~S(f=$HERDR_LIVE_STDERR_FILE; unset HERDR_LIVE_STDERR_FILE; exec "$0" "$@" </dev/null 2>"$f")

  @type result :: %{
          exit_code: integer() | nil,
          stdout: binary(),
          stderr: binary(),
          error: binary() | nil
        }

  @doc """
  `env` is `[{name, value | nil}]` (nil unsets). Options: `:cap` bytes per stream (64 KiB),
  `:timeout_ms` (none) after which the OS process is killed, `:tmp_dir` for the stderr file.
  """
  @spec run([String.t()], Path.t(), [{String.t(), String.t() | nil}], keyword()) :: result()
  def run([cmd | args], cwd, env, opts) do
    case resolve(cmd, cwd) do
      nil -> %{exit_code: nil, stdout: "", stderr: "", error: "command not found: #{cmd}"}
      exe -> spawn_port(exe, args, cwd, env, opts)
    end
  end

  defp resolve(cmd, cwd) do
    if String.contains?(cmd, "/") do
      path = Path.expand(cmd, cwd)
      if File.regular?(path), do: path
    else
      System.find_executable(cmd)
    end
  end

  defp spawn_port(exe, args, cwd, env, opts) do
    cap = opts[:cap] || @cap

    err_file =
      Path.join(
        opts[:tmp_dir] || System.tmp_dir!(),
        "hlcmd-#{System.unique_integer([:positive])}.err"
      )

    env = [{"HERDR_LIVE_STDERR_FILE", err_file} | env]

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
    {code, out, error} = collect(port, pid, {[], 0}, cap, deadline)
    stderr = head(err_file, cap)
    File.rm(err_file)
    %{exit_code: code, stdout: out, stderr: stderr, error: error}
  end

  defp collect(port, pid, {acc, n} = buf, cap, deadline) do
    left =
      if deadline, do: max(deadline - System.monotonic_time(:millisecond), 0), else: :infinity

    receive do
      {^port, {:data, _}} when n >= cap ->
        collect(port, pid, buf, cap, deadline)

      {^port, {:data, d}} ->
        d = binary_part(d, 0, min(byte_size(d), cap - n))
        collect(port, pid, {[acc, d], n + byte_size(d)}, cap, deadline)

      {^port, {:exit_status, s}} ->
        {s, IO.iodata_to_binary(acc), nil}
    after
      left ->
        # exactly the pid we started (sh exec'd into the command), never by name
        System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
        drain(port)
        {nil, IO.iodata_to_binary(acc), "timed out"}
    end
  end

  # the port closes itself on the exit status; drop what it sent meanwhile
  defp drain(port) do
    receive do
      {^port, {:data, _}} -> drain(port)
      {^port, {:exit_status, _}} -> :ok
    after
      2_000 -> :ok
    end
  end

  defp head(file, cap) do
    case File.open(file, [:read, :binary]) do
      {:ok, f} ->
        data = IO.binread(f, cap)
        File.close(f)
        if is_binary(data), do: data, else: ""

      {:error, _} ->
        ""
    end
  end
end
