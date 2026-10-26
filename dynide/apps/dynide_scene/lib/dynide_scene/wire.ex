defmodule DynideScene.Wire do
  @moduledoc """
  Wire contract for remote clients over a byte stream (local unix socket, or an SSH
  relay to it). Pure: no processes, no system calls.

  Framing: `<<len::32-big, etf::binary-size(len)>>`, `etf = :erlang.term_to_binary(term)`,
  on a raw (`{:packet, :raw}`) stream so a partial frame can be carried in a buffer
  (and in a handoff blob). Frames are decoded with `binary_to_term(.., [:safe])`; the
  server additionally rejects client frames that are not plain data (no pids, refs,
  funs, ports) before `validate_client_frame/1`. A frame over the size limit or one that
  does not decode closes only that connection; an invalid frame gets a
  `{:notice, %{level: :warning, text: "frame rejected: ..."}}` and the connection stays.
  Limits: `max_client_frame/0` (pastes up to 16 MiB plus overhead), `max_server_frame/0`.

  Auth: the first frame on every connection is `{:auth, token}`; a wrong or missing token
  gets `{:refused, "bad token"}` and a close. The token is the content of the file at
  `paths/2` `:token`; the SSH relay reads it on the server host, so it never crosses to
  the client machine.

  Client to server frames:

    * `{:auth, token :: binary}`
    * `{:attach, %{version: 1, client_id: 1..64 bytes of [0-9A-Za-z_-], session: binary | nil, kind: :term | :gui,
      size: %{cols, rows}, cell_px: {w, h} | nil, caps: map,
      target: :session | {:pane, pane_id, :observe | :control}}}`
    * `{:input, wire_seq :: non_neg_integer, event}` (event per `DynideScene.Event`)
    * `{:caps, map}`
    * `{:detach}`

  Server to client frames: `{:attached, %{resumed: boolean | :handoff, session: binary}}`,
  `{:refused, reason :: binary}`, and every `DynideScene.Protocol` server message
  (scene, damage, rows, notice, alert, ack, handoff, clipboard, bell, open_url, detached,
  input_mode). Scenes on the wire carry `{:inline, rows}` panes; see `DynideScene.Scene.Pane`.
  """

  alias DynideScene.{Event, Protocol}

  @version 1
  @max_client_frame 33_554_432
  @max_server_frame 67_108_864

  @spec version() :: 1
  def version, do: @version

  @spec max_client_frame() :: pos_integer
  def max_client_frame, do: @max_client_frame

  @spec max_server_frame() :: pos_integer
  def max_server_frame, do: @max_server_frame

  @spec encode(term) :: iodata
  def encode(term) do
    etf = :erlang.term_to_binary(term)
    [<<byte_size(etf)::32-big>>, etf]
  end

  @spec decode(binary, pos_integer) :: {:ok, [term], binary} | {:error, :too_large | :bad_term}
  def decode(buffer, max), do: decode(buffer, max, [])

  defp decode(<<len::32-big, _::binary>>, max, _acc) when len > max, do: {:error, :too_large}

  defp decode(<<len::32-big, etf::binary-size(len), rest::binary>>, max, acc) do
    case safe_term(etf) do
      {:ok, term} -> decode(rest, max, [term | acc])
      :error -> {:error, :bad_term}
    end
  end

  defp decode(rest, _max, acc), do: {:ok, Enum.reverse(acc), rest}

  defp safe_term(etf) do
    {:ok, :erlang.binary_to_term(etf, [:safe])}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Socket, token and API socket paths. `env` is a map of environment variables (an empty
  value counts as unset). The client socket is `$DYNIDE_CLIENT_SOCK`, else
  `client.sock` in the API socket's directory; the token is `client.token` beside it.
  """
  @spec paths(%{optional(binary) => binary}, binary) :: %{
          socket: Path.t(),
          token: Path.t(),
          api: Path.t()
        }
  def paths(env, home) do
    api =
      get(env, "DYNIDE_API") || Path.join([state_dir(env, home), "dynide", "api.sock"])

    socket = get(env, "DYNIDE_CLIENT_SOCK") || Path.join(Path.dirname(api), "client.sock")
    %{socket: socket, token: Path.join(Path.dirname(socket), "client.token"), api: api}
  end

  defp state_dir(env, home),
    do: get(env, "XDG_STATE_HOME") || Path.join([home, ".local", "state"])

  defp get(env, key) do
    case Map.get(env, key) do
      v when v in [nil, ""] -> nil
      v -> v
    end
  end

  @spec validate_client_frame(term) :: :ok | {:error, binary}
  def validate_client_frame({:auth, t}) when is_binary(t), do: :ok
  def validate_client_frame({:attach, %{} = a}), do: validate_attach(a)

  def validate_client_frame({:input, seq, event}) when is_integer(seq) and seq >= 0,
    do: Event.validate(event)

  def validate_client_frame({:input, _, _}),
    do: {:error, "input: wire_seq must be non_neg_integer"}

  def validate_client_frame({:caps, %{}}), do: :ok
  def validate_client_frame({:detach}), do: :ok
  def validate_client_frame(other), do: {:error, "unknown client frame #{inspect(other)}"}

  @spec validate_server_frame(term) :: :ok | {:error, binary}
  def validate_server_frame({:attached, %{resumed: r, session: s}})
      when (is_boolean(r) or r == :handoff) and is_binary(s),
      do: :ok

  def validate_server_frame({:refused, reason}) when is_binary(reason), do: :ok
  def validate_server_frame(other), do: Protocol.validate_server_msg(other)

  @attach_keys [:version, :client_id, :session, :kind, :size, :cell_px, :caps, :target]

  defp client_id?(id), do: is_binary(id) and id =~ ~r/\A[0-9A-Za-z_-]{1,64}\z/

  defp validate_attach(a) do
    cond do
      not Enum.all?(@attach_keys, &Map.has_key?(a, &1)) ->
        {:error, "attach: missing required keys #{inspect(@attach_keys)}"}

      not client_id?(a.client_id) ->
        {:error, "attach.client_id: expected 1..64 bytes of [0-9A-Za-z_-]"}

      not (is_nil(a.session) or is_binary(a.session)) ->
        {:error, "attach.session: expected binary or nil"}

      a.kind not in [:term, :gui] ->
        {:error, "attach.kind: expected :term or :gui"}

      not valid_target?(a.target) ->
        {:error, "attach.target: expected :session or {:pane, id, mode}"}

      not is_map(a.caps) ->
        {:error, "attach.caps: expected map"}

      true ->
        validate_shared(a)
    end
  end

  # size and cell_px rules are the in-VM attach's
  defp validate_shared(a) do
    Protocol.validate_client_msg({:attach, Map.merge(a, %{transport: :inline, client: self()})})
  end

  defp valid_target?(:session), do: true
  defp valid_target?({:pane, id, m}), do: is_integer(id) and id > 0 and m in [:observe, :control]
  defp valid_target?(_), do: false
end
