defmodule HerdrServer.Plugins.PanesTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.Handlers.Plugins, as: Handler
  alias HerdrServer.Api.Handlers.Topology
  alias HerdrServer.App.{Commands, Modal, Store}
  alias HerdrServer.App.Modal.Popup
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Plugins.{Env, Install}
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

  # herdr-workspace-selector's picker entry
  [[panes]]
  id = "picker"
  title = "\u200B"
  placement = "popup"
  width = 64
  height = "70%"
  command = ["bash"]

  [[panes]]
  id = "gone"
  title = "Gone"
  placement = "split"
  command = ["./no-such-script.sh"]
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

  defp pop(extra \\ %{}),
    do:
      Handler.handle("plugin.pane.open", Map.merge(%{plugin_id: "gh", entrypoint: "pop"}, extra))

  test "popup opens an M17 popup with no pane identity; its exit pops it" do
    next = Store.snapshot().session.next_id
    assert {:ok, %{type: "pane_info", pane: pane}} = pop(%{env: %{"HERDR_PANE_ID" => "p99"}})

    assert %{pane_id: "p#{next}", label: "Pop", focused: true, tab_id: "w1:t1"} ==
             Map.take(pane, ~w(pane_id label focused tab_id)a)

    assert pane.cols > 0 and pane.rows > 0

    app = Store.snapshot()
    assert %{kind: :popup, pane: ^next, title: "Pop"} = Modal.top(app)
    refute Map.has_key?(app.session.panes, next)
    e = Map.new(Fake.Keeper.last_spec().env)
    refute Map.has_key?(e, "HERDR_PANE_ID")
    assert e["HERDR_PLUGIN_ENTRYPOINT_ID"] == "pop"
    assert {Fake.Keeper.last_spec().cols, Fake.Keeper.last_spec().rows} == {pane.cols, pane.rows}

    # one popup at a time (herdr's ui_busy)
    assert {:error, :ui_busy, _, %{reason: "ui_busy"}} = pop()

    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(next))
    Fake.Pty.kill(pty, :term)

    assert Enum.any?(1..100, fn _ ->
             Store.snapshot().focus.modal == [] or (Process.sleep(10) && false)
           end)
  end

  test "popup sizes: the request's, else the entry's (the workspace selector's manifest)" do
    assert {:ok, %{pane: p}} = pop(%{entrypoint: "picker"})
    area = Store.snapshot().session.area
    want = Popup.size(%{width: {:cells, 64}, height: {:percent, 70}}, area).inner
    assert {p.cols, p.rows} == {want.w, want.h}
    assert %{title: "\u200B"} = Modal.top(Store.snapshot())
    {:ok, _} = Topology.handle("popup.close", %{})

    assert {:ok, %{pane: p}} = pop(%{entrypoint: "picker", width: "50%", height: 10})
    want = Popup.size(%{width: {:percent, 50}, height: {:cells, 10}}, area).inner
    assert {p.cols, p.rows} == {want.w, want.h}
  end

  test "popup targets the active pane only and takes herdr's sizes" do
    for extra <- [%{workspace_id: 1}, %{target_pane_id: 1}, %{direction: "down"}] do
      assert {:error, :invalid_params, "overlay and popup plugin panes target the active pane", _} =
               pop(extra)
    end

    assert {:error, :invalid_params, _, _} = pop(%{width: "120"})
    assert {:error, :invalid_params, _, _} = open(%{target_pane_id: 1, width: 10})
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

  test "the VM-only env is blanked in a plugin pane (the pty env cannot unset)" do
    System.put_env("HERDR_BROKER_SOCK", "/tmp/live-broker.sock")
    on_exit(fn -> System.delete_env("HERDR_BROKER_SOCK") end)
    assert {:ok, _} = open(%{target_pane_id: 1, env: %{"HERDR_BROKER_SOCK" => "/evil"}})
    e = Map.new(Fake.Keeper.last_spec().env)
    assert Enum.all?(Env.vm_only(), &(e[&1] == ""))
    assert e["HERDR_BROKER_SOCK"] == ""
  end

  test "a disabled plugin is failed / plugin_disabled" do
    {:ok, _} = Install.set_enabled("gh", false)
    assert {:error, :failed, _, %{reason: "plugin_disabled"}} = open(%{target_pane_id: 1})
  end

  test "a missing pane command is failed with the command named" do
    assert {:error, :failed, msg, %{reason: "plugin_pane_open_failed"}} =
             open(%{entrypoint: "gone", target_pane_id: 1})

    assert msg =~ "command not found: ./no-such-script.sh"
  end

  test "placement checks follow herdr" do
    for {placement, extra} <- [
          {"split", %{workspace_id: 1}},
          {"zoomed", %{workspace_id: 1}},
          {"tab", %{target_pane_id: 1}},
          {"tab", %{direction: "down"}},
          {"overlay", %{workspace_id: 1}},
          {"overlay", %{target_pane_id: 1}},
          {"overlay", %{direction: "down"}}
        ] do
      assert {:error, :invalid_params, _, %{reason: "invalid_params"}} =
               open(Map.put(extra, :placement, placement)),
             inspect({placement, extra})
    end

    assert {:ok, _} = open(%{placement: "zoomed", target_pane_id: 1, focus: false})
    assert {:ok, _} = open(%{placement: "tab", workspace_id: 1, focus: false})
  end
end
