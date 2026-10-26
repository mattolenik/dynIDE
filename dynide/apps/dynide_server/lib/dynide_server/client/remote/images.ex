defmodule DynideServer.Client.Remote.Images do
  @moduledoc """
  Which kitty images a socket client still needs (pure). A conn keeps the set of
  `{pane_id, {image_id, fp}}` it sent; before each scene it sends the images the scene's
  `graphics` reference that are not in it, then prunes the set to the scene, so an image
  that leaves the scene (hidden pane, deleted image) is sent again when it comes back,
  matching the client, which drops images its scene no longer references.
  """

  alias DynideScene.Scene
  alias DynideScene.Scene.Graphic

  @type key :: {pos_integer, {pos_integer, non_neg_integer}}

  @doc "Unsent keys of `scene`, each once, with its first placement."
  @spec missing(Scene.t(), MapSet.t(key)) :: [
          {pos_integer, {pos_integer, non_neg_integer}, Graphic.t()}
        ]
  def missing(%Scene{panes: panes}, sent) do
    for p <- panes, g <- p.graphics, not MapSet.member?(sent, {p.id, g.image}) do
      {p.id, g.image, g}
    end
    |> Enum.uniq_by(fn {id, key, _} -> {id, key} end)
  end

  @doc "`sent` without the keys `scene` does not reference."
  @spec prune(MapSet.t(key), Scene.t()) :: MapSet.t(key)
  def prune(sent, %Scene{panes: panes}),
    do:
      MapSet.intersection(sent, MapSet.new(for p <- panes, g <- p.graphics, do: {p.id, g.image}))

  @doc "The payload of a withheld image (over the cap), from its placement."
  @spec withheld(Graphic.t()) :: Graphic.image()
  def withheld(%{format: f, size: {w, h}, bytes: b}),
    do: %{format: f, width: w, height: h, bytes: b, data: nil}
end
