defmodule HerdrServer.Plugins.PanesTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.Handlers.Plugins, as: Handler
  alias HerdrServer.App.{Commands, Store}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Plugins.Install
  alias HerdrServer.Test.PluginDirs

  @toml """
  [[panes]]
  id = "preview"
  title = "Preview"
  placement = "split"
  command = ["bash", "preview.sh"]

  [[panes]]
  id = "pop"
  title = "Pop"
  placement = "popup"
  command = ["bash"]
  """

  setup do
    base = PluginDirs.use_tmp()
    Store.reset()
    on_exit(&Store.reset/0)
    {:ok, _, _} = Store.request({Commands, :noop, []})
    dir = PluginDirs.plugin(Path.join(base, "gh"), "gh", @toml)
    {:ok, _} = Install.link(dir, true)
    %{root: dir}
  end

  defp open(extra),
    do:
      Handler.handle(
        "plugin.pane.open",
        Map.merge(%{plugin_id: "gh", entrypoint: "preview"}, extra)
      )

  test "split: the manifest command in the plugin root, authoritative env, titled", %{root: root} do
    env = %{"GITHUB_URL" => "u", "HERDR_PLUGIN_ID" => "evil", "HERDR_PANE_ID" => "p99"}
    assert {:ok, %{type: "pane_info", pane: pane}} = open(%{target_pane_id: 1, env: env})

    spec = Fake.Keeper.last_spec()

    assert {spec.cmd, spec.args, spec.cwd} ==
             {System.find_executable("bash"), ["preview.sh"], root}

    e = Map.new(spec.env)
    assert map_size(e) == length(spec.env)
    id = Store.snapshot().session.next_id - 1
    assert pane.pane_id == "p#{id}"

    assert Map.take(e, ~w(GITHUB_URL HERDR_PLUGIN_ID HERDR_PANE_ID HERDR_PLUGIN_ENTRYPOINT_ID)) ==
             %{
               "GITHUB_URL" => "u",
               "HERDR_PLUGIN_ID" => "gh",
               "HERDR_PANE_ID" => "p#{id}",
               "HERDR_PLUGIN_ENTRYPOINT_ID" => "preview"
             }

    app = Store.snapshot()
    meta = app.session.panes[id]
    assert meta.name == "Preview"
    assert meta.plugin == %{"plugin_id" => "gh", "entrypoint" => "preview"}
    # focus defaults to true
    assert app.focus.pane == id
    assert Commands.locate(app, id) == Commands.locate(app, 1)

    assert {:ok, %{type: "ok"}} = Handler.handle("plugin.pane.focus", %{pane_id: id})
    assert {:ok, %{type: "ok"}} = Handler.handle("plugin.pane.close", %{pane_id: id})
    refute Map.has_key?(Store.snapshot().session.panes, id)
  end

  test "tab placement adds a tab holding the plugin pane" do
    tabs = fn -> hd(Store.snapshot().session.workspaces).tabs end
    assert length(tabs.()) == 1
    assert {:ok, %{pane: _}} = open(%{placement: "tab", focus: false})
    assert length(tabs.()) == 2
    id = Store.snapshot().session.next_id - 1
    assert Store.snapshot().session.panes[id].plugin["entrypoint"] == "preview"
    assert Store.snapshot().focus.pane == 1
  end

  test "popup is not available yet" do
    assert {:error, :not_available, _, %{requires: "M17 popups"}} =
             Handler.handle("plugin.pane.open", %{plugin_id: "gh", entrypoint: "pop"})
  end

  test "unknown plugin, entrypoint or target pane is not_found" do
    assert {:error, :not_found, _, _} = open(%{plugin_id: "nope"})
    assert {:error, :not_found, _, _} = open(%{entrypoint: "nope"})
    assert {:error, :not_found, _, _} = open(%{target_pane_id: 99})
  end

  test "a caller env name with '=' is invalid_params" do
    assert {:error, :invalid_params, _, %{reason: "invalid_env"}} = open(%{env: %{"A=B" => "x"}})
  end

  test "focus and close refuse a pane that is not a plugin pane" do
    assert {:error, :not_found, _, _} = Handler.handle("plugin.pane.close", %{pane_id: 1})
    assert {:error, :not_found, _, _} = Handler.handle("plugin.pane.focus", %{pane_id: 1})
    assert Map.has_key?(Store.snapshot().session.panes, 1)
  end
end
