defmodule HerdrServer.App.Store.MirrorTest do
  use ExUnit.Case, async: true

  alias HerdrServer.App.Actions
  alias HerdrServer.App.Store.Mirror

  test "keep_monotonic keeps every id counter at least the live app's" do
    restored = elem(Actions.init(%{cols: 80, rows: 24}), 0)
    {live, _} = Actions.new_tab(restored)
    {live, _} = Actions.new_workspace(live)
    s = Mirror.keep_monotonic(restored, live).session

    assert {s.next_id, s.next_workspace_id, s.next_tab_id} ==
             {live.session.next_id, live.session.next_workspace_id, live.session.next_tab_id}

    assert s.next_tab_id > restored.session.next_tab_id
    assert s.next_workspace_id > restored.session.next_workspace_id
  end
end
