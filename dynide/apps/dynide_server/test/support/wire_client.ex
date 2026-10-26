defmodule DynideServer.Test.WireClient do
  @moduledoc """
  Test helper: a raw `DynideScene.Wire` client for `DynideServer.Client.Socket`.
  The receive buffer of each socket lives in the calling process's dictionary.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias DynideScene.{Cell, Wire}
  alias DynideServer.App.Store
  alias DynideServer.Client.{Remote, Socket}

  @opts [:binary, packet: :raw, active: false]

  @doc "Clean app, a listener on a tmp path. Returns `%{path, token}`."
  def setup_listener do
    reset()
    on_exit(&reset/0)
    dir = Path.join(System.tmp_dir!(), "hlc#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "c.sock")
    token_path = Path.join(dir, "c.token")
    start_supervised!({Socket, path: path, token_path: token_path})
    %{path: path, token: Socket.token(token_path), token_path: token_path}
  end

  defp reset do
    for sup <- [Remote.Supervisor, DynideServer.Client.Supervisor],
        {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
        do: DynamicSupervisor.terminate_child(sup, pid)

    Store.reset()
  end

  def connect(path) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, @opts, 5000)
    s
  end

  def send_frame(s, term), do: :gen_tcp.send(s, Wire.encode(term))

  def attach_info(opts \\ []) do
    Map.merge(
      %{
        version: Wire.version(),
        client_id: "c#{System.unique_integer([:positive])}",
        session: nil,
        kind: :term,
        size: %{cols: 80, rows: 24},
        cell_px: nil,
        caps: %{},
        target: :session
      },
      Map.new(opts)
    )
  end

  @doc "Connects, authenticates and attaches; returns the socket (attached frame unread)."
  def attach(%{path: path, token: token}, opts \\ []) do
    s = connect(path)
    :ok = send_frame(s, {:auth, token})
    :ok = send_frame(s, {:attach, attach_info(opts)})
    s
  end

  @doc "The next frame, `{:error, :closed}` or `{:error, :timeout}`."
  def recv_frame(s, timeout \\ 2000) do
    buf = Process.get({__MODULE__, s}, "")

    case Wire.decode(buf, Wire.max_server_frame()) do
      {:ok, [frame | _], _} ->
        # decode one at a time: keep the bytes after the first frame
        <<len::32-big, _::binary-size(len), rest::binary>> = buf
        Process.put({__MODULE__, s}, rest)
        frame

      {:ok, [], _} ->
        case :gen_tcp.recv(s, 0, timeout) do
          {:ok, data} ->
            Process.put({__MODULE__, s}, buf <> data)
            recv_frame(s, timeout)

          {:error, _} = e ->
            e
        end
    end
  end

  @doc "Skips frames until `fun` holds; flunks after `timeout` ms overall."
  def recv_until(s, fun, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    until(s, fun, deadline)
  end

  defp until(s, fun, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    case recv_frame(s, left) do
      {:error, why} ->
        ExUnit.Assertions.flunk("no matching frame: #{inspect(why)}")

      frame ->
        if fun.(frame), do: frame, else: until(s, fun, deadline)
    end
  end

  @doc "Reads until the server closes the socket; flunks after `timeout` ms."
  def recv_closed(s, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      recv_frame(s, max(deadline - System.monotonic_time(:millisecond), 0))
    end)
    |> Enum.find(&match?({:error, _}, &1))
    |> case do
      {:error, :closed} -> :closed
      other -> ExUnit.Assertions.flunk("not closed: #{inspect(other)}")
    end
  end

  @doc "Whether a scene or rows frame carries a row whose text contains `str`."
  def shows?({:scene, scene}, str), do: Enum.any?(scene.panes, &rows_show?(inline(&1.rows), str))

  def shows?({:rows, _, _, rows}, str), do: rows_show?(rows, str)
  def shows?(_, _), do: false

  defp inline({:inline, rows}), do: rows
  defp inline(_), do: []

  defp rows_show?(rows, str), do: Enum.any?(rows, fn {_, bin} -> text(bin) =~ str end)

  def text(row),
    do: row |> Cell.decode_row() |> Enum.map_join(&if(&1.glyph == "", do: " ", else: &1.glyph))
end
