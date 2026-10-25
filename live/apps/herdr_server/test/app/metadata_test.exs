defmodule HerdrServer.App.MetadataTest do
  use ExUnit.Case, async: true

  alias HerdrServer.App.{Actions, Metadata}

  defp fresh, do: elem(Actions.init(%{cols: 80, rows: 24}), 0)

  test "a patch adds and replaces keys; nil removes one" do
    m = Metadata.apply(nil, %{"b" => "2", "a" => "1"}, "s", nil, nil, 0)
    assert Metadata.visible(m) == [{"a", "1"}, {"b", "2"}]
    m = Metadata.apply(m, %{"a" => "one", "b" => nil}, "s", nil, nil, 0)
    assert Metadata.visible(m) == [{"a", "one"}]
  end

  test "a seq at most the source's last is dropped; other sources have their own" do
    m = Metadata.apply(nil, %{"k" => "1"}, "s", 5, nil, 0)
    assert Metadata.apply(m, %{"k" => "2"}, "s", 5, nil, 0) == m
    assert Metadata.apply(m, %{"k" => "2"}, "s", 4, nil, 0) == m
    assert Metadata.visible(Metadata.apply(m, %{"k" => "2"}, "s", 6, nil, 0)) == [{"k", "2"}]
    assert Metadata.visible(Metadata.apply(m, %{"k" => "3"}, "t", 1, nil, 0)) == [{"k", "3"}]
    # no seq always applies
    assert Metadata.visible(Metadata.apply(m, %{"k" => "4"}, "s", nil, nil, 0)) == [{"k", "4"}]
    assert m["__seq"] == %{"s" => 5}
  end

  test "ttl: keys expire at now + ttl; a later report without ttl keeps its key" do
    m = Metadata.apply(nil, %{"a" => "x", "b" => "y"}, "s", nil, 100, 1_000)
    assert Metadata.next_expiry(m) == 1_100
    m = Metadata.apply(m, %{"b" => "z"}, "s", nil, nil, 1_050)
    assert Metadata.visible(Metadata.drop_expired(m, 1_099)) == [{"a", "x"}, {"b", "z"}]
    m = Metadata.drop_expired(m, 1_100)
    assert Metadata.visible(m) == [{"b", "z"}]
    assert Metadata.next_expiry(m) == nil
  end

  test "at most 32 sequenced sources: a 33rd fails, tracked ones go on" do
    app = fresh()

    app =
      Enum.reduce(1..32, app, fn i, app ->
        {app, []} = Metadata.report(app, {:pane, 1}, %{"k" => "#{i}"}, "s#{i}", 1, nil, 0)
        app
      end)

    assert {^app, [{:notice, %{level: :warning, text: text}}]} =
             Metadata.report(app, {:pane, 1}, %{"k" => "x"}, "s33", 1, nil, 0)

    assert text =~ "32 sequenced sources"
    # pure apply drops it too, so a replay never re-opens
    m = app.session.panes[1].metadata
    assert Metadata.apply(m, %{"k" => "x"}, "s33", 1, nil, 0) == m
    # an unsequenced report and a tracked source still apply
    assert {_, []} = Metadata.report(app, {:pane, 1}, %{"k" => "y"}, "s33", nil, nil, 0)
    {app, []} = Metadata.report(app, {:pane, 1}, %{"k" => "z"}, "s1", 2, nil, 0)
    assert map_size(app.session.panes[1].metadata["__seq"]) == 32
    assert Metadata.visible(app.session.panes[1].metadata) == [{"k", "z"}]
  end

  test "a stale seq is dropped before the key cap is checked" do
    app = fresh()
    {app, []} = Metadata.report(app, {:pane, 1}, Map.new(1..32, &{"k#{&1}", "v"}), "s", 5, nil, 0)
    assert {^app, []} = Metadata.report(app, {:pane, 1}, %{"k33" => "v"}, "s", 5, nil, 0)
  end

  test "normalize: herdr's source and key rules; values cleaned, empty clears" do
    assert {:ok, "hook", %{"a" => "review ready", "e" => nil, "n" => nil}} =
             Metadata.normalize(" hook ", %{"a" => "  review\n ready ", "e" => " \t", "n" => nil})

    assert {:ok, _, %{"a" => v}} = Metadata.normalize("s", %{"a" => String.duplicate("x", 90)})
    assert String.length(v) == 80
    assert {:error, _} = Metadata.normalize("bad source", %{"a" => "x"})
    assert {:error, _} = Metadata.normalize("s", %{})
    assert {:error, _} = Metadata.normalize("s", %{"bad.key" => "x"})
    assert {:error, _} = Metadata.normalize("s", %{"__seq" => "x"})
    assert {:error, _} = Metadata.normalize("s", Map.new(1..17, &{"k#{&1}", "v"}))
  end

  test "report and the server-internal expire on the app" do
    app = fresh()
    {app, fx} = Metadata.report(app, {:pane, 1}, %{"a" => "x"}, "s", nil, 50, 1_000)
    assert fx == [{:expire_at, 1_050}]
    {app, fx} = Metadata.report(app, {:workspace, 1}, %{"w" => "y"}, "s", nil, 10, 1_000)
    assert fx == [{:expire_at, 1_010}]
    assert {^app, []} = Metadata.report(app, {:pane, 9}, %{"a" => "x"}, "s", nil, nil, 0)

    {app, fx} = Actions.apply(app, {:metadata_expire, 1_010})
    assert fx == [{:expire_at, 1_050}]
    assert Metadata.visible(hd(app.session.workspaces).metadata) == []
    assert Metadata.visible(app.session.panes[1].metadata) == [{"a", "x"}]
    {app, []} = Actions.apply(app, {:metadata_expire, 2_000})
    assert Metadata.visible(app.session.panes[1].metadata) == []
  end

  test "more than 32 keys is a warning and no change" do
    app = fresh()
    full = Map.new(1..32, &{"k#{&1}", "v"})
    {app, _} = Metadata.report(app, {:pane, 1}, full, "s", nil, nil, 0)

    assert {^app, [{:notice, %{level: :warning}}]} =
             Metadata.report(app, {:pane, 1}, %{"k33" => "v"}, "s", nil, nil, 0)

    # replacing or clearing within the cap is fine
    assert {_, []} =
             Metadata.report(app, {:pane, 1}, %{"k1" => "w", "k2" => nil}, "s", nil, nil, 0)
  end
end
