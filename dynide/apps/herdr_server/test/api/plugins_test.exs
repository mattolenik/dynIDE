defmodule HerdrServer.Api.PluginsTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Plugins.Paths
  alias HerdrServer.Test.{ApiClient, PluginDirs}

  setup do
    base = PluginDirs.use_tmp()
    Store.reset()
    on_exit(&Store.reset/0)
    path = base <> "/a.sock"
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    %{s: ApiClient.connect(path), base: base}
  end

  defp ok!(s, method, params) do
    reply = ApiClient.call(s, method, params)
    assert %{"result" => r} = reply, "#{method}: #{inspect(reply)}"
    assert Spec.validate_result(method, r) == :ok
    r
  end

  defp err(s, method, params) do
    assert %{"error" => e} = ApiClient.call(s, method, params)
    {:ok, m} = Spec.fetch(method)
    assert String.to_existing_atom(e["code"]) in m.errors, "#{method}: #{inspect(e)}"
    e
  end

  test "link, list, disable, enable, config_dir, uninstall", %{s: s, base: base} do
    dir = PluginDirs.plugin(base <> "/p", "t.p")

    assert %{"plugin" => %{"plugin_id" => "t.p", "enabled" => false, "error" => nil}} =
             ok!(s, "plugin.link", %{"path" => dir, "enabled" => false})

    assert %{"plugins" => [%{"plugin_id" => "t.p"}]} = ok!(s, "plugin.list", %{})
    assert %{"plugins" => []} = ok!(s, "plugin.list", %{"plugin_id" => "t.x"})
    assert %{"plugin" => %{"enabled" => true}} = ok!(s, "plugin.enable", %{"plugin_id" => "t.p"})

    assert %{"plugin" => %{"enabled" => false}} =
             ok!(s, "plugin.disable", %{"plugin_id" => "t.p"})

    assert %{"path" => p} = ok!(s, "plugin.config_dir", %{"plugin_id" => "t.p"})
    assert p == Paths.plugin_config_dir("t.p") and File.dir?(p)

    assert %{"plugin_id" => "t.p"} = ok!(s, "plugin.uninstall", %{"target" => "t.p"})
    assert %{"plugins" => []} = ok!(s, "plugin.list", %{})
  end

  test "update: nothing to update answers empty lists; a linked plugin is not_applicable",
       %{s: s, base: base} do
    assert %{"updated" => [], "up_to_date" => []} = ok!(s, "plugin.update", %{"yes" => true})
    ok!(s, "plugin.link", %{"path" => PluginDirs.plugin(base <> "/p", "t.p")})
    assert %{"updated" => [], "up_to_date" => []} = ok!(s, "plugin.update", %{})

    assert %{"code" => "failed", "data" => %{"reason" => "not_applicable"}} =
             err(s, "plugin.update", %{"target" => "t.p"})

    # --ref without a target: invalid_params, herdr's code in data.reason (as the spec says)
    assert %{"code" => "invalid_params", "data" => %{"reason" => "invalid_plugin_source"}} =
             err(s, "plugin.update", %{"ref" => "main"})
  end

  test "a broken manifest lists with error", %{s: s, base: base} do
    dir = PluginDirs.plugin(base <> "/p", "t.p")
    ok!(s, "plugin.link", %{"path" => dir})
    File.write!(dir <> "/herdr-plugin.toml", "id = ")

    assert %{"plugins" => [%{"error" => "plugin_manifest_parse_failed" <> _}]} =
             ok!(s, "plugin.list", %{})
  end

  test "not_found, failed and invalid_params carry herdr's reason", %{s: s, base: base} do
    for m <- ~w(plugin.enable plugin.disable) do
      assert %{"code" => "not_found", "data" => %{"reason" => "plugin_not_found"}} =
               err(s, m, %{"plugin_id" => "t.none"})
    end

    assert %{"code" => "not_found"} = err(s, "plugin.uninstall", %{"target" => "t.none"})

    assert %{"code" => "failed", "data" => %{"reason" => "plugin_manifest_not_found"}} =
             err(s, "plugin.link", %{"path" => base <> "/none"})

    assert %{"code" => "invalid_params", "data" => %{"reason" => "invalid_plugin_id"}} =
             err(s, "plugin.config_dir", %{"plugin_id" => "../x"})

    assert %{"code" => "invalid_params", "data" => %{"reason" => "invalid_plugin_source"}} =
             err(s, "plugin.install", %{"source" => "owner"})
  end

  @tag :examples
  test "install without yes answers the preview", %{s: s} do
    src = Path.join(PluginDirs.examples(), "rust-release-check")

    assert %{
             "code" => "failed",
             "message" => msg,
             "data" => %{"reason" => "confirmation_required", "preview" => pv}
           } =
             err(s, "plugin.install", %{"source" => src})

    assert msg =~ "--yes"
    assert pv["build"] == [["cargo", "build", "--release"]]
    assert %{"plugins" => []} = ok!(s, "plugin.list", %{})
  end
end
