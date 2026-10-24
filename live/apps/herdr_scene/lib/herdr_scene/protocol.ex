defmodule HerdrScene.Protocol do
  @moduledoc """
  Client/server protocol, identical for every transport.

  Client to server:

    * `GenServer.call(endpoint(), {:attach, %{kind: :term | :gui, transport: :ref | :inline,
      size: %{cols, rows}, cell_px: {w, h} | nil, caps: map, client: pid}})`,
      reply `{:ok, session_pid, %{rows: {m, f, a}}}`
    * `{:input, from_pid, seq, event}` (event per `HerdrScene.Event`)
    * `{:detach}`

  Server to client:

    * `{:scene, %HerdrScene.Scene{}}`
    * `{:damage, pane_id, gen}` (ref transport) / `{:rows, pane_id, gen, [{n, binary}]}` (inline)
    * `{:notice, %{level: :info | :warning | :error, text: binary}}`
    * `{:ack, seq}`
    * `{:handoff, map}`

  The server publishes the focused-pane fast path under `fast_path_key/0` in
  `:persistent_term`.
  """

  alias HerdrScene.{Event, Scene}

  @attach_keys [:kind, :transport, :size, :cell_px, :caps, :client]

  @spec endpoint() :: :herdr_client_endpoint
  def endpoint, do: :herdr_client_endpoint

  @spec fast_path_key() :: {__MODULE__, :fast_path}
  def fast_path_key, do: {__MODULE__, :fast_path}

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

  def validate_server_msg({:ack, seq}) do
    if nat?(seq), do: :ok, else: {:error, "ack.seq: expected non_neg_integer"}
  end

  def validate_server_msg({:handoff, %{}}), do: :ok
  def validate_server_msg(other), do: {:error, "unknown server message #{inspect(other)}"}

  defp validate_attach(a) do
    cond do
      Enum.sort(Map.keys(a)) != Enum.sort(@attach_keys) ->
        {:error, "attach: expected keys #{inspect(@attach_keys)}"}

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

  defp size?(%{cols: c, rows: r}), do: is_integer(c) and c > 0 and is_integer(r) and r > 0
  defp size?(_), do: false

  defp cell_px?({w, h}), do: is_integer(w) and w > 0 and is_integer(h) and h > 0
  defp cell_px?(_), do: false

  defp row?({n, b}), do: nat?(n) and is_binary(b)
  defp row?(_), do: false

  defp nat?(n), do: is_integer(n) and n >= 0
end
