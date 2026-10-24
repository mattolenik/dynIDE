defmodule HerdrServer.Api.SpecTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Api.Spec
  alias HerdrServer.Api.Spec.Doc

  test "every method name is unique and every error is a known code" do
    methods = Spec.methods()
    names = Enum.map(methods, & &1.name)
    assert names == Enum.uniq(names)
    assert length(names) == 38

    for m <- methods do
      assert Enum.all?(m.errors, &(&1 in Spec.error_codes())), m.name
      assert Map.has_key?(Spec.results(), m.result), "#{m.name} -> #{m.result}"
      assert {:ok, ^m} = Spec.fetch(m.name)
      if m.params != [], do: assert(:invalid_params in m.errors, m.name)
    end

    assert Spec.fetch("nope") == :error

    assert Spec.error_codes() ==
             ~w(parse_error invalid_request unknown_method invalid_params not_found
                not_available failed timeout backpressure events_lost internal)a
  end

  test "validate_params parses ids and rejects unknown keys" do
    assert Spec.validate_params("pane.split", %{"pane_id" => "p2", "direction" => "right"}) ==
             {:ok, %{pane_id: 2, direction: "right"}}

    assert {:error, msg} = Spec.validate_params("pane.split", %{"bogus" => 1})
    assert msg =~ "bogus"

    assert {:error, msg} =
             Spec.validate_params("pane.split", %{"pane_id" => "p2", "direction" => "left"})

    assert msg =~ "direction"

    assert {:error, msg} =
             Spec.validate_params("pane.split", %{"pane_id" => "2", "direction" => "right"})

    assert msg =~ "pane_id"

    assert Spec.validate_params("tab.get", %{"tab_id" => "w1:t2"}) == {:ok, %{tab_id: {1, 2}}}
    assert Spec.validate_params("ping", %{}) == {:ok, %{}}
    assert {:error, _} = Spec.validate_params("nope", %{})
  end

  test "ranges, lists and objects" do
    assert {:error, msg} = Spec.validate_params("reload.rollback", %{"n" => 0})
    assert msg =~ "n"
    assert Spec.validate_params("reload.rollback", %{"n" => 3}) == {:ok, %{n: 3}}

    assert {:error, _} =
             Spec.validate_params("pane.split", %{"direction" => "down", "ratio" => 0.95})

    assert {:ok, %{ratio: 0.5, focus: true}} =
             Spec.validate_params("pane.split", %{
               "direction" => "down",
               "ratio" => 0.5,
               "focus" => true
             })

    assert {:error, msg} =
             Spec.validate_params("pane.send_keys", %{"pane_id" => "p1", "keys" => []})

    assert msg =~ "keys"

    assert Spec.validate_params("events.subscribe", %{
             "subscriptions" => [%{"type" => "pane.updated", "pane_id" => "p4"}]
           }) == {:ok, %{subscriptions: [%{type: "pane.updated", pane_id: 4}]}}

    assert {:error, msg} =
             Spec.validate_params("events.subscribe", %{
               "subscriptions" => [%{"type" => "pane.updated", "extra" => 1}]
             })

    assert msg =~ "extra"
    assert {:error, _} = Spec.validate_params("events.subscribe", %{"subscriptions" => []})
  end

  test "required params" do
    assert {:error, msg} = Spec.validate_params("pane.read", %{})
    assert msg =~ "pane_id"
    assert {:ok, %{pane_id: 1}} = Spec.validate_params("pane.read", %{"pane_id" => "p1"})
  end

  test "validate_result checks type and fields" do
    pane = %{
      "pane_id" => "p1",
      "tab_id" => "w1:t1",
      "workspace_id" => "w1",
      "title" => nil,
      "focused" => true,
      "cols" => 80,
      "rows" => 24
    }

    assert Spec.validate_result("pane.get", %{"type" => "pane_info", "pane" => pane}) == :ok

    assert {:error, msg} =
             Spec.validate_result("pane.get", %{"type" => "pane_list", "panes" => []})

    assert msg =~ "type"
    assert {:error, msg} = Spec.validate_result("pane.get", %{"type" => "pane_info"})
    assert msg =~ "pane"

    assert {:error, msg} =
             Spec.validate_result("pane.get", %{
               "type" => "pane_info",
               "pane" => %{pane | "cols" => "x"}
             })

    assert msg =~ "cols"
    assert Spec.validate_result("pane.send_text", %{"type" => "ok"}) == :ok

    assert Spec.validate_result("ping", %{"type" => "pong", "version" => "0.1.0", "gen" => 1}) ==
             :ok
  end

  test "api.md is generated from the spec" do
    assert File.read!(Doc.path()) == Doc.markdown(),
           "docs/herdr-live/api.md is stale: run `mix herdr.api.docs` from live/"
  end
end
