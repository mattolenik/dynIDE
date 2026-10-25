defmodule HerdrServer.Plugins.EnvTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Plugins.{Env, Paths}

  @plugin %{"plugin_id" => "t.p", "plugin_root" => "/r/t"}

  test "the herdr contract, optional values unset when absent" do
    ctx = %{"workspace_id" => "w1", "tab_id" => "w1:t1", "focused_pane_id" => "p2"}
    env = Map.new(Env.for_command(@plugin, ctx, %{action_id: "go"}))

    assert %{
             "HERDR_ENV" => "1",
             "HERDR_PLUGIN_ID" => "t.p",
             "HERDR_PLUGIN_ROOT" => "/r/t",
             "HERDR_PLUGIN_ACTION_ID" => "go",
             "HERDR_WORKSPACE_ID" => "w1",
             "HERDR_TAB_ID" => "w1:t1",
             "HERDR_PANE_ID" => "p2",
             "HERDR_PLUGIN_EVENT" => nil,
             "HERDR_PLUGIN_CLICKED_URL" => nil
           } = env

    assert env["HERDR_PLUGIN_CONFIG_DIR"] == Paths.plugin_config_dir("t.p")
    assert env["HERDR_PLUGIN_STATE_DIR"] == Paths.plugin_state_dir("t.p")
    assert JSON.decode!(env["HERDR_PLUGIN_CONTEXT_JSON"]) == ctx

    assert is_binary(env["HERDR_SOCKET_PATH"]) and
             env["HERDR_LIVE_API"] == env["HERDR_SOCKET_PATH"]
  end

  test "HERDR_BIN_PATH is always a herdr-live launcher, never a bare herdr" do
    env = Map.new(Env.for_command(@plugin, %{}, %{}))
    bin = env["HERDR_BIN_PATH"]
    assert env["HERDR_LIVE_BIN"] == bin
    assert File.regular?(bin), inspect(bin)
    assert Path.basename(bin) == "herdr-live"
  end

  test "event, entrypoint, link and click modifiers in shift,alt,ctrl order" do
    ctx = %{
      "clicked_url" => "u",
      "link_handler_id" => "h",
      "click_modifiers" => ["ctrl", "shift"]
    }

    kind = %{event: "tab.created", event_json: "{}", entrypoint: "main"}
    env = Map.new(Env.for_command(@plugin, ctx, kind))

    assert %{
             "HERDR_PLUGIN_EVENT" => "tab.created",
             "HERDR_PLUGIN_EVENT_JSON" => "{}",
             "HERDR_PLUGIN_ENTRYPOINT_ID" => "main",
             "HERDR_PLUGIN_CLICKED_URL" => "u",
             "HERDR_PLUGIN_LINK_HANDLER_ID" => "h",
             "HERDR_PLUGIN_CLICK_MODIFIERS" => "shift,ctrl",
             "HERDR_PANE_ID" => nil
           } = env
  end

  test "the VM's handoff and launcher vars are unset" do
    env = Map.new(Env.for_command(@plugin, %{}, %{}))

    for v <- ~w(HERDR_BROKER_SOCK HERDR_LIVE_GEN HERDR_LIVE_RUNTIME_DIR HERDR_LIVE_STATE_DIR),
        do: assert(Map.fetch(env, v) == {:ok, nil}, v)
  end

  test "authoritative values win over the caller's" do
    auth = Env.for_command(@plugin, %{"focused_pane_id" => "p2"}, %{})

    merged =
      Map.new(
        Env.merge(%{"HERDR_PANE_ID" => "p99", "HERDR_PLUGIN_ID" => "evil", "X" => "1"}, auth)
      )

    assert merged["HERDR_PANE_ID"] == "p2"
    assert merged["HERDR_PLUGIN_ID"] == "t.p"
    assert merged["X"] == "1"
  end
end
