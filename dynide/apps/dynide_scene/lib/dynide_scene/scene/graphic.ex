defmodule DynideScene.Scene.Graphic do
  @moduledoc """
  Kitty graphics in the scene: the placement maps of `Scene.Pane.graphics` and the image
  payloads a client fetches (`images` MFA of the attach reply) or receives
  (`{:image, pane_id, {image_id, fp}, payload}` on inline transports).

  A placement (the pane's list is sorted by `z`):

    * `image` - `{image_id, fp}`: the child's image id in that pane and the content
      fingerprint; a new fingerprint means new pixels
    * `placement` - stable id per (image, placement) in the pane, virtual (unicode
      placeholder) runs included
    * `x`, `y` - pane-relative top-left cell in the viewport; negative when the image is
      partly scrolled off or left of the pane; `cols`, `rows` - the cell grid it covers
      (it may extend past the pane: the client clips)
    * `x_off`, `y_off` - sub-cell pixel offset of the top-left corner
    * `src` - `{sx, sy, sw, sh}` source rect in image pixels; `sw`/`sh` 0 means to the
      image edge
    * `px` - `{pw, ph}` rendered size in pixels, 0 when derived from the cells
    * `z` - the child's z-index; `size` - `{w, h}` image pixels; `format` - one of
      `formats/0`; `bytes` - data length

  An image payload: `%{format, width, height, bytes, data}`; `data` is nil when the
  server withheld it (over its forwarding cap) and the client shows a placeholder.
  """

  @formats [:rgb, :rgba, :png]

  @type format :: :rgb | :rgba | :png
  @type t :: %{
          image: {pos_integer, non_neg_integer},
          placement: pos_integer,
          x: integer,
          y: integer,
          cols: pos_integer,
          rows: pos_integer,
          x_off: non_neg_integer,
          y_off: non_neg_integer,
          src: {non_neg_integer, non_neg_integer, non_neg_integer, non_neg_integer},
          px: {non_neg_integer, non_neg_integer},
          z: integer,
          size: {pos_integer, pos_integer},
          format: format,
          bytes: non_neg_integer
        }
  @type image :: %{
          format: format,
          width: pos_integer,
          height: pos_integer,
          bytes: non_neg_integer,
          data: binary | nil
        }

  @spec formats() :: [format]
  def formats, do: @formats

  @checks [
    image: :image,
    placement: :pos,
    x: :int,
    y: :int,
    cols: :pos,
    rows: :pos,
    x_off: :nat,
    y_off: :nat,
    src: {:nat, 4},
    px: {:nat, 2},
    z: :int,
    size: {:pos, 2},
    format: :format,
    bytes: :nat
  ]

  @image_checks [format: :format, width: :pos, height: :pos, bytes: :nat, data: :data]

  @doc "Checks one placement map."
  @spec validate(term) :: :ok | {:error, binary}
  def validate(%{} = g), do: check(g, @checks)
  def validate(other), do: {:error, "graphic: expected a map, got #{inspect(other)}"}

  @doc "Checks one image payload."
  @spec validate_image(term) :: :ok | {:error, binary}
  def validate_image(%{} = i), do: check(i, @image_checks)
  def validate_image(other), do: {:error, "image: expected a map, got #{inspect(other)}"}

  defp check(map, checks) do
    case Enum.find(checks, fn {k, kind} -> not ok?(kind, Map.get(map, k, :__missing__)) end) do
      nil -> :ok
      {k, _} -> {:error, "#{k}: invalid #{inspect(Map.get(map, k))}"}
    end
  end

  defp ok?(:int, v), do: is_integer(v)
  defp ok?(:nat, v), do: is_integer(v) and v >= 0
  defp ok?(:pos, v), do: is_integer(v) and v > 0
  defp ok?(:format, v), do: v in @formats
  defp ok?(:data, v), do: is_nil(v) or is_binary(v)
  defp ok?(:image, {id, fp}), do: ok?(:pos, id) and ok?(:nat, fp)

  defp ok?({kind, n}, t) when is_tuple(t) and tuple_size(t) == n,
    do: t |> Tuple.to_list() |> Enum.all?(&ok?(kind, &1))

  defp ok?(_, _), do: false
end
