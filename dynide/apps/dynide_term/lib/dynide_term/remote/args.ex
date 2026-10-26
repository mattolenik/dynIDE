defmodule DynideTerm.Remote.Args do
  @moduledoc """
  The remote client's argv (pure): `attach [<host>] [<session>]` and
  `terminal attach|observe <pane_id> [--host <host>]`, into `DynideTerm.Remote.Conn`
  options (`transport`, `session`, `target`). No host is the local client socket
  (`DynideScene.Wire.paths/2` from `env`); a host goes through ssh (`ssh_command/2`).
  Pane ids are `p<N>` (or `N`), N > 0.
  """

  alias DynideScene.Wire

  @usage [
    "attach [<host>] [<session>]",
    "terminal attach <pane_id> [--host <host>]",
    "terminal observe <pane_id> [--host <host>]"
  ]

  @doc "Usage lines, without the `herdr-live ` prefix."
  @spec usage_lines() :: [binary]
  def usage_lines, do: @usage

  @spec parse([binary], %{optional(binary) => binary}) :: {:ok, keyword} | {:usage, binary}
  def parse(argv, env) do
    case parsed(argv) do
      {:ok, host, session, target} ->
        {:ok, [transport: transport(host, session, env), session: session, target: target]}

      :usage ->
        {:usage, Enum.map_join(@usage, "\n", &"  herdr-live #{&1}") |> then(&"usage:\n#{&1}")}
    end
  end

  defp parsed(["attach" | rest]) do
    case OptionParser.parse(rest, strict: []) do
      {[], args, []} when length(args) <= 2 ->
        [host, session] = args ++ List.duplicate(nil, 2 - length(args))
        {:ok, host, session, :session}

      _ ->
        :usage
    end
  end

  defp parsed(["terminal", verb | rest]) when verb in ["attach", "observe"] do
    mode = if verb == "attach", do: :control, else: :observe

    with {opts, [pane], []} <- OptionParser.parse(rest, strict: [host: :string]),
         [_, n] <- Regex.run(~r/^p?([0-9]+)$/, pane),
         id when id > 0 <- String.to_integer(n) do
      {:ok, opts[:host], nil, {:pane, id, mode}}
    else
      _ -> :usage
    end
  end

  defp parsed(_), do: :usage

  defp transport(nil, _session, env) do
    paths = Wire.paths(env, Map.get(env, "HOME", ""))
    {:unix, paths.socket, paths.token}
  end

  defp transport(host, session, _env), do: {:ssh, host, session}

  @doc """
  `{executable, args}` for the ssh relay (R13): `$HERDR_LIVE_SSH` split on spaces (else
  `ssh`), then `-T -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3
  <host> <remote_bin> attach-relay`, `remote_bin` = `$HERDR_LIVE_REMOTE_BIN` else
  `herdr-live`.
  """
  @spec ssh_command(binary, %{optional(binary) => binary}) :: {binary, [binary]}
  def ssh_command(host, env) do
    [exe | pre] = String.split(get(env, "HERDR_LIVE_SSH") || "ssh")
    bin = get(env, "HERDR_LIVE_REMOTE_BIN") || "herdr-live"
    opts = ~w(-T -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
    {exe, pre ++ opts ++ [host, bin, "attach-relay"]}
  end

  defp get(env, key) do
    case String.trim(Map.get(env, key) || "") do
      "" -> nil
      v -> v
    end
  end
end
