defmodule HerdrServer.Pane.Links do
  @moduledoc """
  A pane's link URL and vt by pane id, for the pointer path (`Client.PointerIo`) and the
  API (`pane.link.activate`). Reads `Pane.Rows` and the keeper; no process.
  """

  alias HerdrScene.Cell
  alias HerdrServer.Client.Links
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.Rows

  @doc """
  The URL of the link at viewport cell (`x`, `y`) of pane `id`: a text URL or an OSC 8
  link's URI (any scheme); nil for none, `:error` when the pane has no rows.
  """
  @spec url_at(term, non_neg_integer, non_neg_integer) :: String.t() | nil | :error
  def url_at(id, x, y) do
    case Rows.fetch(id) do
      {_gen, rows, _cursor} when tuple_size(rows) > 0 ->
        uri(id, Links.at(rows, Cell.cols(elem(rows, 0)), x, y), x, y)

      {_gen, _rows, _cursor} ->
        nil

      nil ->
        :error
    end
  end

  @doc "Pane `id`'s vt handle from the keeper, or `:error`."
  @spec vt(term) :: {:ok, term} | :error
  def vt(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt}} <- Kernel.keeper().lookup(kid),
         do: {:ok, vt},
         else: (_ -> :error)
  end

  defp uri(_id, %{url: url}, _x, _y), do: url

  defp uri(id, %{id: _}, x, y) do
    with {:ok, vt} <- vt(id), %{uri: uri} <- Kernel.vt().link_at(vt, x, y), do: uri
  end

  defp uri(_id, nil, _x, _y), do: nil
end
