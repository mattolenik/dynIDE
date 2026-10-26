defmodule DynideServer.Client.LinksTest do
  use ExUnit.Case, async: true
  alias DynideScene.Cell
  alias DynideServer.Client.Links

  # Packed rows of width `w` from `{text, link_id_per_col}` specs.
  defp rows(w, specs) do
    specs
    |> Enum.map(fn
      {text, links} -> row(w, text, links)
      text -> row(w, text, [])
    end)
    |> List.to_tuple()
  end

  defp row(w, text, links) do
    gs = String.graphemes(text)

    gs
    |> Kernel.++(List.duplicate("", w - length(gs)))
    |> Enum.with_index()
    |> Enum.map(fn {g, i} ->
      %Cell{glyph: if(g == " ", do: "", else: g), link: Enum.at(links, i, 0)}
    end)
    |> Cell.encode_row()
  end

  defp ids(pairs), do: Enum.flat_map(pairs, fn {id, n} -> List.duplicate(id, n) end)

  test "osc 8 run wrapping two rows" do
    r = rows(10, [{"see link12", ids([{0, 4}, {5, 6}])}, {"34 more", ids([{5, 2}])}])
    want = %{id: 5, from: {4, 0}, to: {1, 1}}
    assert Links.at(r, 10, 6, 0) == want
    assert Links.at(r, 10, 0, 1) == want
    assert Links.at(r, 10, 3, 1) == nil
  end

  test "osc 8 non-http link is still returned with its id; safe? is false" do
    r = rows(12, [{"mailto:x", ids([{7, 8}])}])
    assert Links.at(r, 12, 2, 0) == %{id: 7, from: {0, 0}, to: {7, 0}}
    refute Links.safe?("mailto:x")
    refute Links.safe?("file:///etc/passwd")
    assert Links.safe?("https://a")
    assert Links.safe?("http://a")
  end

  test "blank tail of a wide cell inherits its link" do
    cells = [
      %Cell{glyph: "a"},
      %Cell{glyph: "世", width: 2, link: 3},
      %Cell{glyph: "", width: 0},
      %Cell{glyph: "b"}
    ]

    r = {Cell.encode_row(cells)}
    assert Links.at(r, 4, 2, 0) == %{id: 3, from: {1, 0}, to: {2, 0}}
  end

  test "osc 8 runs over the cap return nil" do
    w = 100
    r = List.to_tuple(for _ <- 1..83, do: row(w, String.duplicate("x", w), List.duplicate(9, w)))
    assert Links.at(r, w, 0, 0) == nil
  end

  test "text url keeps a balanced paren" do
    r = rows(30, ["(https://e.com/a_(b))"])
    want = %{id: 0, url: "https://e.com/a_(b)", from: {1, 0}, to: {19, 0}}
    assert Links.at(r, 30, 5, 0) == want
    assert Links.at(r, 30, 20, 0) == nil
    assert Links.at(r, 30, 0, 0) == nil
  end

  test "text url continues onto the next row and back" do
    r = rows(10, ["go https:/", "/e.com/x y"])
    want = %{id: 0, url: "https://e.com/x", from: {3, 0}, to: {7, 1}}
    assert Links.at(r, 10, 4, 0) == want
    assert Links.at(r, 10, 2, 1) == want
    assert Links.at(r, 10, 9, 1) == nil
  end

  test "blank cell, plain word or out of range is nil" do
    r = rows(10, ["hi there"])
    assert Links.at(r, 10, 2, 0) == nil
    assert Links.at(r, 10, 0, 0) == nil
    assert Links.at(r, 10, 12, 0) == nil
    assert Links.at(r, 10, 0, 3) == nil
  end
end
