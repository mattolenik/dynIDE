defmodule HerdrScene.Protocol do
  @moduledoc """
  Client/server protocol, identical for every transport.

  Client to server:

    * `GenServer.call(endpoint(), {:attach, %{kind: :term | :gui, transport: :ref | :inline,
      size: %{cols, rows}, cell_px: {w, h} | nil, caps: map, client: pid}})`,
      reply `{:ok, session_pid, %{rows: {m, f, a}}}`; `apply(m, f, [pane_id | a])` returns
      `{gen, rows_tuple, cursor | nil} | nil` (element n of `rows_tuple` = packed row n,
      `cursor` pane-relative `%{x, y, shape, visible}`)
    * `{:input, from_pid, seq, event}` (event per `HerdrScene.Event`)
    * `{:detach}`
    * `{:caps, map}`: caps update after attach. Documented keys (the map is open):
      `colors: %{fg: rgb | nil, bg: rgb | nil, palette: %{0..255 => rgb}}`,
      `scheme: :dark | :light | nil`; `rgb` is `{r, g, b}`, each 0..255

  Server to client:

    * `{:scene, %HerdrScene.Scene{}}`
    * `{:damage, pane_id, gen}` (ref transport) / `{:rows, pane_id, gen, [{n, binary}]}` (inline)
    * `{:notice, %{level: :info | :warning | :error, text: binary}}`
    * `{:alert, %{kind: :notification, level: :info | :attention | :done,
      title: binary | nil, body: binary | nil, pane: pos_integer | nil,
      sound: :done | :request | nil}}`: an agent notification for the client to surface
      (toast, sound, desktop notification) as it chooses; all keys required. `kind` is
      required so the alert vocabulary can grow; pane bells are not alerts
    * `{:ack, seq}`
    * `{:handoff, map}`
    * `{:clipboard, %{text: binary, source: :selection | :pane}}`: text for the client to put
      on its host clipboard
    * `{:bell, pane_id}`
    * `{:open_url, binary}`: only `http://` and `https://` URLs are valid
    * `{:detached, reason :: atom}`: the server ended this client's session (`:requested`:
      the client's own detach binding or `{:detach}`); the session is gone after it
    * `{:input_mode, :terminal | :prefix | :resize | :copy}`: this client's own input mode
      changed (input modes are per client). Sent to the `from_pid` of the `{:input, ...}`
      that caused it, before that input's `{:ack, seq}`; a session starts in `:terminal`,
      except a re-attach that restores a mirrored mode, which sends it to the attach's
      `client` pid right after attaching.
      A client may take the fast path only while its own mode is `:terminal`

  Inline rows: a scene pane's `{:inline, rows}` is a partial update (listed rows replace
  those of the client's cache, unlisted rows keep it; see `Scene.Pane`). Over a socket
  the same messages travel as `HerdrScene.Wire` frames.

  Generations: `{:ref, id, layout_gen}` in a scene is the pane's layout generation;
  the `gen` of `{:damage, ...}`, `{:rows, ...}` and the rows MFA is its content
  generation. They are unrelated and must not be compared (see `Scene.Pane`).

  Maps are open: required keys must be valid, unknown extra keys are accepted.

  The server publishes the focused-pane fast path under `fast_path_key/0` in
  `:persistent_term`. Its `passthrough` reflects shared state only (a focused pane, no
  modal); the client's own mode comes from `{:input_mode, mode}`.

  Handoff: the in-VM local client's top-level process registers as `local_client_name/0`
  (the server waits for it to stop on `:begin` before the next VM may open the tty), and
  the server keeps the current handoff phase (`:begin | :aborted | :released`, absent
  otherwise) under `handoff_key/0` in `:persistent_term`.
  """

  alias HerdrScene.{Event, Scene}

  @attach_keys [:kind, :transport, :size, :cell_px, :caps, :client]
  @alert_keys [:kind, :level, :title, :body, :pane, :sound]

  @spec endpoint() :: :herdr_client_endpoint
  def endpoint, do: :herdr_client_endpoint

  @spec fast_path_key() :: {__MODULE__, :fast_path}
  def fast_path_key, do: {__MODULE__, :fast_path}

  @spec local_client_name() :: :herdr_local_client
  def local_client_name, do: :herdr_local_client

  @spec handoff_key() :: {__MODULE__, :handoff}
  def handoff_key, do: {__MODULE__, :handoff}

  @spec validate_client_msg(term) :: :ok | {:error, binary}
  def validate_client_msg({:attach, %{} = a}), do: validate_attach(a)

  def validate_client_msg({:input, from, seq, event}) do
    cond do
      not is_pid(from) -> {:error, "input.from: expected pid"}
      not nat?(seq) -> {:error, "input.seq: expected non_neg_integer"}
      true -> Event.validate(event)
    end
  end

  def validate_client_msg({:detach}), do: :ok
  def validate_client_msg({:caps, %{}}), do: :ok
  def validate_client_msg(other), do: {:error, "unknown client message #{inspect(other)}"}

  @spec validate_server_msg(term) :: :ok | {:error, binary}
  def validate_server_msg({:scene, scene}) do
    case Scene.validate(scene) do
      :ok -> :ok
      {:error, msgs} -> {:error, Enum.join(msgs, "; ")}
    end
  end

  def validate_server_msg({:damage, id, gen}) when is_integer(id) and id > 0 do
    if nat?(gen), do: :ok, else: {:error, "damage.gen: expected non_neg_integer"}
  end

  def validate_server_msg({:rows, id, gen, rows}) when is_integer(id) and id > 0 do
    if nat?(gen) and is_list(rows) and Enum.all?(rows, &row?/1),
      do: :ok,
      else: {:error, "rows: expected gen and [{non_neg_integer, binary}]"}
  end

  def validate_server_msg({:notice, %{level: l, text: t}})
      when l in [:info, :warning, :error] and is_binary(t),
      do: :ok

  def validate_server_msg({:alert, %{} = a}) do
    if Enum.all?(@alert_keys, &Map.has_key?(a, &1)),
      do: validate_alert(a),
      else: {:error, "alert: missing required keys #{inspect(@alert_keys)}"}
  end

  def validate_server_msg({:ack, seq}) do
    if nat?(seq), do: :ok, else: {:error, "ack.seq: expected non_neg_integer"}
  end

  def validate_server_msg({:handoff, %{}}), do: :ok
  def validate_server_msg({:detached, reason}) when is_atom(reason), do: :ok

  def validate_server_msg({:input_mode, m}) when m in [:terminal, :prefix, :resize, :copy],
    do: :ok

  def validate_server_msg({:clipboard, %{text: t, source: s}})
      when is_binary(t) and s in [:selection, :pane],
      do: :ok

  def validate_server_msg({:bell, id}) when is_integer(id) and id > 0, do: :ok

  def validate_server_msg({:open_url, <<"http://", _::binary>>}), do: :ok
  def validate_server_msg({:open_url, <<"https://", _::binary>>}), do: :ok

  def validate_server_msg(other), do: {:error, "unknown server message #{inspect(other)}"}

  @doc "Validates the reply to `{:attach, _}`."
  @spec validate_attach_reply(term) :: :ok | {:error, binary}
  def validate_attach_reply({:ok, pid, %{rows: {m, f, a}}})
      when is_pid(pid) and is_atom(m) and is_atom(f) and is_list(a),
      do: :ok

  def validate_attach_reply({:error, reasons}) when is_list(reasons), do: :ok
  def validate_attach_reply(other), do: {:error, "unknown attach reply #{inspect(other)}"}

  defp validate_attach(a) do
    cond do
      not Enum.all?(@attach_keys, &Map.has_key?(a, &1)) ->
        {:error, "attach: missing required keys #{inspect(@attach_keys)}"}

      a.kind not in [:term, :gui] ->
        {:error, "attach.kind: expected :term or :gui"}

      a.transport not in [:ref, :inline] ->
        {:error, "attach.transport: expected :ref or :inline"}

      true ->
        validate_attach_fields(a)
    end
  end

  defp validate_attach_fields(a) do
    cond do
      not size?(a.size) ->
        {:error, "attach.size: expected %{cols, rows} positive"}

      not (is_nil(a.cell_px) or cell_px?(a.cell_px)) ->
        {:error, "attach.cell_px: expected {w, h} or nil"}

      not is_map(a.caps) ->
        {:error, "attach.caps: expected map"}

      not is_pid(a.client) ->
        {:error, "attach.client: expected pid"}

      true ->
        :ok
    end
  end

  defp validate_alert(a) do
    cond do
      a.kind != :notification ->
        {:error, "alert.kind: expected :notification"}

      a.level not in [:info, :attention, :done] ->
        {:error, "alert.level: unknown #{inspect(a.level)}"}

      true ->
        validate_alert_fields(a)
    end
  end

  defp validate_alert_fields(a) do
    cond do
      not opt_binary?(a.title) ->
        {:error, "alert.title: expected binary or nil"}

      not opt_binary?(a.body) ->
        {:error, "alert.body: expected binary or nil"}

      not (is_nil(a.pane) or (is_integer(a.pane) and a.pane > 0)) ->
        {:error, "alert.pane: expected pos_integer or nil"}

      a.sound not in [:done, :request, nil] ->
        {:error, "alert.sound: expected :done, :request or nil"}

      true ->
        :ok
    end
  end

  defp opt_binary?(v), do: is_nil(v) or is_binary(v)

  defp size?(%{cols: c, rows: r}), do: is_integer(c) and c > 0 and is_integer(r) and r > 0
  defp size?(_), do: false

  defp cell_px?({w, h}), do: is_integer(w) and w > 0 and is_integer(h) and h > 0
  defp cell_px?(_), do: false

  defp row?({n, b}), do: nat?(n) and is_binary(b)
  defp row?(_), do: false

  defp nat?(n), do: is_integer(n) and n >= 0
end
