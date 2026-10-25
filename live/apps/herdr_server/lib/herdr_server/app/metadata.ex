defmodule HerdrServer.App.Metadata do
  @moduledoc """
  Pure: metadata tokens (herdr's `report_metadata`) on a pane
  (`session.panes[id].metadata`) or a workspace (its `metadata`). Not persisted.

  A meta is `%{key => %{value: binary, expires: ms | nil}}` plus `"__seq"`
  (`%{source => seq}`) and `"__seq_order"` (its sources, least recently reported
  first), both kept out of `visible/1`. A report whose `seq` is at most the stored seq
  of its source is dropped; at most 32 sources are tracked, the least recently
  reported dropped first. A nil value removes its key. Times are wall-clock ms
  (`System.system_time(:millisecond)`), so a carried app keeps them across a handoff.

  `report/7` (an API request through the Store) and the server-internal
  `{:metadata_expire, now_ms}` (`expire/2`) return `{:expire_at, ms}` for the earliest
  pending expiry they leave; the Store arms one timer for the earliest of those.
  """

  @max_sources 32
  @max_keys 32
  @max_patch 16
  @max_value 80

  @type meta :: %{optional(binary) => term()}
  @type target :: {:pane, term()} | {:workspace, term()}

  @doc "`meta` with `patch` applied (or unchanged: a stale `seq`)."
  @spec apply(
          meta() | nil,
          %{binary => binary | nil},
          binary,
          integer | nil,
          pos_integer | nil,
          integer
        ) :: meta()
  def apply(meta, patch, source, seq, ttl_ms, now) do
    meta = meta || %{}
    seqs = Map.get(meta, "__seq", %{})

    if seq != nil and is_map_key(seqs, source) and seq <= seqs[source] do
      meta
    else
      expires = ttl_ms && now + ttl_ms

      patch
      |> Enum.reduce(meta, fn
        {k, nil}, m -> Map.delete(m, k)
        {k, v}, m -> Map.put(m, k, %{value: v, expires: expires})
      end)
      |> track(source, seq)
    end
  end

  defp track(meta, _source, nil), do: meta

  defp track(meta, source, seq) do
    order = List.delete(Map.get(meta, "__seq_order", []), source) ++ [source]
    {dropped, order} = Enum.split(order, max(length(order) - @max_sources, 0))
    seqs = meta |> Map.get("__seq", %{}) |> Map.drop(dropped) |> Map.put(source, seq)
    Map.merge(meta, %{"__seq" => seqs, "__seq_order" => order})
  end

  @doc "The token values, sorted by key."
  @spec visible(meta() | nil) :: [{binary, binary}]
  def visible(nil), do: []

  def visible(meta),
    do: meta |> Enum.flat_map(fn {k, t} -> token(k, t) end) |> Enum.sort()

  defp token("__" <> _, _), do: []
  defp token(k, %{value: v}), do: [{k, v}]
  defp token(_, _), do: []

  @doc "The number of keys `meta` would hold after `patch`."
  @spec keys_after(meta() | nil, map()) :: non_neg_integer()
  def keys_after(meta, patch) do
    keys = MapSet.new(visible(meta), &elem(&1, 0))

    patch
    |> Enum.reduce(keys, fn
      {k, nil}, s -> MapSet.delete(s, k)
      {k, _}, s -> MapSet.put(s, k)
    end)
    |> MapSet.size()
  end

  @doc "`meta` without the tokens expired at `now`."
  @spec drop_expired(meta() | nil, integer) :: meta() | nil
  def drop_expired(nil, _now), do: nil

  def drop_expired(meta, now),
    do:
      Map.reject(meta, fn {_, t} -> match?(%{expires: e} when is_integer(e) and e <= now, t) end)

  @doc "The earliest expiry in `meta`, or nil."
  @spec next_expiry(meta() | nil) :: integer | nil
  def next_expiry(nil), do: nil

  def next_expiry(meta) do
    meta
    |> Enum.flat_map(fn
      {_, %{expires: e}} when is_integer(e) -> [e]
      _ -> []
    end)
    |> Enum.min(fn -> nil end)
  end

  @doc """
  herdr's report checks: `source` is 1-80 of ASCII letters, digits and `:._-` (trimmed);
  `tokens` has 1-#{@max_patch} keys of `[A-Za-z0-9_-]{1,32}`, none `__`-prefixed (reserved);
  a value is trimmed, stripped of control characters and cut to #{@max_value} characters, and
  an empty one becomes nil (clears the key).
  """
  @spec normalize(binary, map) :: {:ok, binary, map} | {:error, binary}
  def normalize(source, tokens) do
    source = String.trim(source)

    cond do
      not Regex.match?(~r/\A[A-Za-z0-9:._-]{1,80}\z/, source) ->
        {:error,
         "metadata source must be 1-80 ASCII letters, digits, colon, dot, underscore or hyphen"}

      map_size(tokens) == 0 ->
        {:error, "missing token to set or clear"}

      map_size(tokens) > @max_patch ->
        {:error, "a metadata report may update at most #{@max_patch} tokens"}

      key = Enum.find(Map.keys(tokens), &(not valid_key?(&1))) ->
        {:error, "invalid metadata token key: #{key}"}

      true ->
        {:ok, source, Map.new(tokens, fn {k, v} -> {k, clean(v)} end)}
    end
  end

  defp valid_key?("__" <> _), do: false
  defp valid_key?(k), do: Regex.match?(~r/\A[A-Za-z0-9_-]{1,32}\z/, k)

  defp clean(nil), do: nil

  defp clean(v) do
    v =
      v
      |> String.replace_invalid("")
      |> String.trim()
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.slice(0, @max_value)
      |> String.trim()

    if v == "", do: nil, else: v
  end

  # --- app ---

  @doc """
  A report on `target` (an API request: `Store.request/1`). More than #{@max_keys} keys
  after the patch is a warning notice and no change; a missing target is no change.
  """
  @spec report(map, target(), map, binary, integer | nil, pos_integer | nil, integer) ::
          {map, [tuple]}
  def report(app, target, patch, source, seq, ttl_ms, now) do
    case get(app, target) do
      :error ->
        {app, []}

      {:ok, meta} ->
        if keys_after(meta, patch) > @max_keys do
          text = "metadata may contain at most #{@max_keys} tokens"
          {app, [{:notice, %{level: :warning, text: text}}]}
        else
          meta = __MODULE__.apply(meta, patch, source, seq, ttl_ms, now)
          {put(app, target, meta), expire_at(next_expiry(meta))}
        end
    end
  end

  @doc "Server-internal `{:metadata_expire, now_ms}`: drops every token expired at `now`."
  @spec expire(map, integer) :: {map, [tuple]}
  def expire(app, now) do
    panes =
      Map.new(app.session.panes, fn {id, m} ->
        {id, Map.replace_lazy(m, :metadata, &drop_expired(&1, now))}
      end)

    wss =
      Enum.map(
        app.session.workspaces,
        &Map.replace_lazy(&1, :metadata, fn m -> drop_expired(m, now) end)
      )

    app = %{app | session: %{app.session | panes: panes, workspaces: wss}}

    next =
      Enum.map(Map.values(panes) ++ wss, &next_expiry(Map.get(&1, :metadata)))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    {app, expire_at(next)}
  end

  defp expire_at(nil), do: []
  defp expire_at(ms), do: [{:expire_at, ms}]

  defp get(app, {:pane, id}) do
    case app.session.panes do
      %{^id => m} -> {:ok, Map.get(m, :metadata)}
      _ -> :error
    end
  end

  defp get(app, {:workspace, id}) do
    case Enum.find(app.session.workspaces, &(&1.id == id)) do
      nil -> :error
      ws -> {:ok, Map.get(ws, :metadata)}
    end
  end

  defp put(app, {:pane, id}, meta), do: put_in(app.session.panes[id][:metadata], meta)

  defp put(app, {:workspace, id}, meta) do
    update_in(app.session.workspaces, fn l ->
      Enum.map(l, &if(&1.id == id, do: Map.put(&1, :metadata, meta), else: &1))
    end)
  end
end
