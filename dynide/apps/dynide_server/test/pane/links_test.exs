defmodule DynideServer.Pane.LinksTest do
  use ExUnit.Case, async: true

  alias DynideServer.Pane.Links

  test "a pane with no rows is :error (pane.link.activate covers the URLs)" do
    assert Links.url_at(987_654_321, 0, 0) == :error
    assert Links.vt(987_654_321) == :error
  end
end
