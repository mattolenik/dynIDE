defmodule HerdrServer.Client.Outbox do
  @moduledoc """
  Pure batching and row diff for a socket client's server-side connection.

  Scenes and rows from `Client.Session` are `put/2` as they arrive; `flush/1`
  turns what is pending into wire messages. Rows are compared against what
  the client already has (`sent`), so only changed rows travel. A pending
  scene carries the changes inline (a partial update, see `Scene.Pane`) and
  supersedes pending `{:rows, ...}`. Rows of panes absent from the last scene
  (hidden panes) are dropped; the next scene resends them in full.
  """

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Pane

  @type rows :: %{optional(non_neg_integer) => binary}
  @type t :: %__MODULE__{
          scene: Scene.t() | nil,
          rows: %{optional(pos_integer) => rows},
          sent: %{optional(pos_integer) => rows},
          gens: %{optional(pos_integer) => non_neg_integer},
          last_scene: Scene.t() | nil
        }

  defstruct scene: nil, rows: %{}, sent: %{}, gens: %{}, last_scene: nil

  @spec new() :: t
  def new, do: %__MODULE__{}

  @spec put(
          t,
          {:scene, Scene.t()} | {:rows, pos_integer, non_neg_integer, [{non_neg_integer, binary}]}
        ) :: t
  def put(%__MODULE__{} = t, {:scene, %Scene{} = scene}) do
    rows =
      Enum.reduce(scene.panes, t.rows, fn
        %Pane{id: id, rows: {:inline, list}}, acc -> merge(acc, id, list)
        _ref_pane, acc -> acc
      end)

    %{t | scene: scene, last_scene: scene, rows: rows}
  end

  def put(%__MODULE__{} = t, {:rows, id, gen, list}) do
    %{t | rows: merge(t.rows, id, list), gens: Map.put(t.gens, id, gen)}
  end

  @spec pending?(t) :: boolean
  def pending?(%__MODULE__{scene: nil, rows: rows, sent: sent, last_scene: last}) do
    rows
    |> Map.take(visible_ids(last))
    |> Enum.any?(fn {id, r} -> diff(r, sent[id]) != [] end)
  end

  def pending?(%__MODULE__{}), do: true

  @spec flush(t) :: {[term], t}
  def flush(%__MODULE__{scene: %Scene{} = scene} = t) do
    inline_ids = for %Pane{id: id, rows: {:inline, _}} <- scene.panes, do: id
    keep = Map.take(t.rows, inline_ids)

    panes =
      Enum.map(scene.panes, fn
        %Pane{id: id, rows: {:inline, _}} = p ->
          %{p | rows: {:inline, diff(keep[id] || %{}, t.sent[id])}}

        p ->
          p
      end)

    # ponytail: ref panes (in-VM) never reach an outbox; kept as-is, no diff state.
    {[{:scene, %{scene | panes: panes}}], %{t | scene: nil, rows: keep, sent: keep}}
  end

  def flush(%__MODULE__{} = t) do
    visible = visible_ids(t.last_scene)
    rows = Map.take(t.rows, visible)

    msgs =
      for {id, r} <- Enum.sort(rows), changed = diff(r, t.sent[id]), changed != [] do
        {:rows, id, t.gens[id] || 0, changed}
      end

    {msgs, %{t | rows: rows, sent: Map.merge(t.sent, rows)}}
  end

  @doc "Forget what the client has; the next flush sends everything."
  @spec reset(t) :: t
  def reset(%__MODULE__{} = t), do: %{t | sent: %{}}

  @doc "Resume: resend the last scene with every row."
  @spec full(t) :: {[term], t}
  def full(%__MODULE__{} = t) do
    t = reset(t)
    flush(%{t | scene: t.last_scene})
  end

  defp merge(rows, id, list) do
    Map.update(rows, id, Map.new(list), &Enum.into(list, &1))
  end

  defp diff(rows, sent) do
    sent = sent || %{}
    for {n, bin} <- Enum.sort(rows), Map.get(sent, n) != bin, do: {n, bin}
  end

  defp visible_ids(nil), do: []
  defp visible_ids(%Scene{panes: panes}), do: for(%Pane{id: id} <- panes, do: id)
end
