defmodule DynideTerm.Remote.Notice do
  @moduledoc """
  A client-local notice (disconnected, undecodable frame, refused) shown in the scene's
  `:status` node as its first child, a `:text` node with id `:notice` and the level as
  its token (R14). Pure.
  """

  alias DynideScene.Scene
  alias DynideScene.Scene.Node

  @type notice :: %{level: :info | :warning | :error, text: binary}

  @doc "Sets (or with nil removes) the notice in every `:status` node; no status, no change."
  @spec put(Scene.t(), notice | nil) :: Scene.t()
  def put(%Scene{chrome: %Node{} = root} = scene, notice),
    do: %{scene | chrome: walk(root, notice)}

  def put(scene, _notice), do: scene

  @doc "An empty scene of `size` with only a bottom status row, for a notice before any scene."
  @spec blank(%{cols: pos_integer, rows: pos_integer}) :: Scene.t()
  def blank(%{cols: c, rows: r} = size) do
    status = %Node{role: :status, id: :status, rect: %{x: 0, y: r - 1, w: c, h: 1}}
    %Scene{size: size, chrome: %Node{role: :root, id: :root, children: [status]}}
  end

  defp walk(%Node{role: :status, children: cs} = n, notice) do
    rest = Enum.reject(cs, &match?(%Node{id: :notice}, &1))
    %{n | children: if(notice, do: [notice_node(notice) | rest], else: rest)}
  end

  defp walk(%Node{children: cs} = n, notice), do: %{n | children: Enum.map(cs, &walk(&1, notice))}

  defp notice_node(%{level: level, text: text}),
    do: %Node{role: :text, id: :notice, text: text, token: level}
end
