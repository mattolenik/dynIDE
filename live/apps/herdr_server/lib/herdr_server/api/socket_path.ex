defmodule HerdrServer.Api.SocketPath do
  @moduledoc """
  Where the API socket lives and whether this VM may listen there.

  `path/0`: `$HERDR_LIVE_API`, else `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/api.sock`
  (an empty variable counts as unset, like the launcher's `${VAR:-default}`).

  `prepare/1` checks a path before listening. Only the default dir is created (0700).
  macOS ignores socket modes, so an existing default dir owned by this user is chmodded
  0700 and one owned by another user is refused; a custom path's dir must exist and keeps
  its mode (a warning if group/other can enter). A stale socket at the path is removed;
  another live instance's socket, a non-socket file, a missing dir or a path over 103
  bytes is an error.
  """

  require Logger

  @doc "The API socket path."
  @spec path() :: Path.t()
  def path, do: env("HERDR_LIVE_API") || Path.join(default_dir(), "api.sock")

  defp default_dir do
    state = env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state, "herdr-live")
  end

  defp env(var), do: if(System.get_env(var) in [nil, ""], do: nil, else: System.get_env(var))

  @doc "Readies `path` for a listener: length, dir and a free path."
  @spec prepare(Path.t()) :: :ok | {:error, String.t()}
  def prepare(path) do
    with :ok <- check_length(path),
         :ok <- ensure_dir(Path.dirname(path)),
         do: free(path)
  end

  # sun_path is 104 bytes on macOS, 108 on Linux; longer paths raise badarg
  defp check_length(path) when byte_size(path) > 103, do: {:error, "path too long"}
  defp check_length(_), do: :ok

  # Only the default state dir is created (0700). macOS ignores socket modes, so the dir
  # is the access check: an existing default dir of ours is locked to 0700, one owned by
  # another user is refused; a custom dir is left alone, with a warning if it is open.
  defp ensure_dir(dir) do
    case File.lstat(dir) do
      {:ok, %{type: :directory} = st} ->
        if dir == default_dir(), do: lock(dir, st, my_uid()), else: warn_open(dir, st)

      {:error, :enoent} ->
        if dir == default_dir(), do: create(dir), else: {:error, "#{dir} does not exist"}

      {:ok, %{type: type}} ->
        {:error, "#{dir} is a #{type}, not a directory"}

      {:error, _} = e ->
        errmsg(e)
    end
  end

  @doc false
  # the default dir's check; `my_uid` nil (unknown) never equals a uid, so it is refused
  @spec lock(Path.t(), File.Stat.t(), non_neg_integer() | nil) :: :ok | {:error, String.t()}
  def lock(dir, %{uid: uid, mode: mode}, my_uid) do
    cond do
      uid != my_uid -> {:error, "#{dir} is owned by another user"}
      Bitwise.band(mode, 0o077) != 0 -> errmsg(File.chmod(dir, 0o700))
      true -> :ok
    end
  end

  defp warn_open(dir, %{mode: mode}) do
    if Bitwise.band(mode, 0o077) != 0,
      do: Logger.warning("#{dir} is group/other-accessible: on macOS other users can connect")

    :ok
  end

  defp my_uid do
    with {out, 0} <- System.cmd("id", ["-u"]),
         {uid, ""} <- Integer.parse(String.trim(out)),
         do: uid,
         else: (_ -> nil)
  end

  defp create(dir), do: errmsg(with(:ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)))

  # nothing at the path, or a socket nobody answers on (left by a killed VM): remove it.
  # Anything else is not ours to delete.
  defp free(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :other}} ->
        cond do
          live?(path) -> {:error, "in use by another instance"}
          socket?(path) -> errmsg(File.rm(path))
          true -> {:error, "a non-socket file is in the way"}
        end

      {:ok, %{type: type}} ->
        {:error, "a #{type} is in the way"}

      {:error, _} = e ->
        errmsg(e)
    end
  end

  # File.Stat folds sockets, fifos and devices into :other
  defp socket?(path), do: match?({_, 0}, System.cmd("test", ["-S", path]))

  defp live?(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 200) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      {:error, _} ->
        false
    end
  end

  defp errmsg({:error, r}) when is_atom(r), do: {:error, :file.format_error(r) |> to_string()}
  defp errmsg(other), do: other
end
