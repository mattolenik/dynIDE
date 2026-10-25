defmodule HerdrServer.Plugins.RegistryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HerdrServer.App.{Commands, Store}
  alias HerdrServer.Plugins.{Install, Paths, Registry}
  alias HerdrServer.Test.PluginDirs

  setup do
    base = PluginDirs.use_tmp()
    Store.reset()
    on_exit(&Store.reset/0)
    # alerts toast only once there is a session
    {:ok, _, _} = Store.request({Commands, :noop, []})
    %{base: base}
  end

  test "before the first session an alert only logs and initialises nothing" do
    Store.reset()
    File.mkdir_p!(Paths.config_dir())
    File.write!(Paths.registry(), "{not json")
    Store.subscribe(self())

    assert capture_log(fn -> assert Registry.plugins() == [] end) =~ "plugins.json"
    refute_receive {:alert, _}, 100
    assert Store.snapshot() == nil
  end

  test "round trip: update writes sorted entries 0600 under a 0700 dir; entries reads them" do
    e = fn id ->
      %{
        "plugin_id" => id,
        "plugin_root" => "/r",
        "manifest_path" => "/r/m",
        "enabled" => true,
        "source" => %{"kind" => "local"}
      }
    end

    assert Registry.entries() == []
    assert {:ok, [_, _]} = Registry.update(fn es -> es ++ [e.("b"), e.("a")] end)
    assert [%{"plugin_id" => "a"}, %{"plugin_id" => "b"}] = Registry.entries()
    assert File.stat!(Paths.registry()).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Paths.config_dir()).mode |> Bitwise.band(0o777) == 0o700
  end

  test "corrupt plugins.json lists [] with one warning and one alert" do
    File.mkdir_p!(Paths.config_dir())
    File.write!(Paths.registry(), "{not json")
    Store.subscribe(self())

    log = capture_log(fn -> assert Registry.plugins() == [] end)
    assert log =~ "plugins.json"
    assert_receive {:alert, %{kind: :notification, level: :attention, pane: nil, body: body}}
    assert body =~ "plugins.json"

    log = capture_log(fn -> assert Registry.plugins() == [] end)
    refute log =~ "plugins.json"
    refute_receive {:alert, _}, 100
    assert {:error, _} = Registry.update(& &1)
  end

  test "a plugin whose manifest is gone lists with error, the others still list", %{base: base} do
    a = PluginDirs.plugin(base <> "/a", "t.a")
    b = PluginDirs.plugin(base <> "/b", "t.b")
    assert {:ok, _} = Install.link(a, true)
    assert {:ok, _} = Install.link(b, false)
    File.rm!(Path.join(a, "herdr-plugin.toml"))
    Store.subscribe(self())

    log =
      capture_log(fn ->
        assert [
                 %{
                   "plugin_id" => "t.a",
                   "error" => "plugin_manifest_not_found" <> _,
                   "actions" => []
                 },
                 %{"plugin_id" => "t.b", "error" => nil, "name" => "T", "enabled" => false}
               ] =
                 Registry.plugins()
      end)

    assert log =~ "t.a"
    assert_receive {:alert, %{body: body}}
    assert body =~ "t.a"
    capture_log(fn -> Registry.plugins() end)
    refute_receive {:alert, _}, 100

    assert {:ok, %{"plugin_id" => "t.b"}} = Registry.find("t.b")
    assert :error = Registry.find("t.c")
  end

  test "a manifest edited on disk shows on the next read", %{base: base} do
    a = PluginDirs.plugin(base <> "/a", "t.a")
    {:ok, _} = Install.link(a, true)
    PluginDirs.plugin(a, "t.a", ~s([[actions]]\nid = "go"\ntitle = "Go"\ncommand = ["true"]))
    assert {:ok, %{"actions" => [%{"id" => "go"}]}} = Registry.find("t.a")
  end
end
