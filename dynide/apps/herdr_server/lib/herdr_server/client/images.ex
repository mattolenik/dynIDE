defmodule HerdrServer.Client.Images do
  @moduledoc """
  The attach reply's `images` MFA (`HerdrScene.Protocol`): a client fetches the pixel
  data of an image a scene placement references, read from the pane's vt.
  """

  alias HerdrServer.Kernel
  alias HerdrServer.Pane.Rows

  @doc "Image `image_id` of pane `pane_id` (`HerdrScene.Scene.Graphic.image/0`), or nil."
  @spec fetch(pos_integer, pos_integer) :: HerdrScene.Scene.Graphic.image() | nil
  def fetch(pane_id, image_id) do
    with kid when kid != nil <- Rows.kernel_id(pane_id),
         {:ok, %{vt: vt}} <- Kernel.keeper().lookup(kid) do
      Kernel.vt().graphics_image(vt, image_id)
    else
      _ -> nil
    end
  end
end
