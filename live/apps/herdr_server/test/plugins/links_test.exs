defmodule HerdrServer.Plugins.LinksTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Plugins.{Install, Links, Menu, Registry, Runtime}
  alias HerdrServer.Test.{ApiClient, PluginDirs}

  setup do
    base = PluginDirs.use_tmp()
    Store.reset()
    on_exit(&Store.reset/0)
    on_exit(fn -> Menu.put([]) end)
    :persistent_term.erase({Runtime, :startup_ran})
    %{base: base}
  end

  defp start_runtime do
    start_supervised!({Task.Supervisor, name: HerdrServer.Plugins.Tasks})
    start_supervised!(Runtime)
  end

  # a plugin whose `go` action writes its link env to <base>/out, on urls matching `pattern`
  defp handler_plugin(base, id, pattern, enabled \\ true) do
    out = Path.join(base, "out")

    toml = """
    [[actions]]
    id = "go"
    title = "Go"
    command = ["sh", "-c", "printf '%s|%s|%s|%s' \\"$HERDR_PLUGIN_CLICKED_URL\\" \\"$HERDR_PLUGIN_LINK_HANDLER_ID\\" \\"$HERDR_PLUGIN_CLICK_MODIFIERS\\" \\"$HERDR_PANE_ID\\" > #{out}"]

    [[link_handlers]]
    id = "h"
    title = "H"
    pattern = "#{pattern}"
    action = "go"
    """

    {:ok, _} = Install.link(PluginDirs.plugin(Path.join(base, id), id, toml), enabled)
    out
  end

  defp wait_file(path, tries \\ 100) do
    cond do
      File.exists?(path) and File.read!(path) != "" -> File.read!(path)
      tries > 0 -> Process.sleep(50) && wait_file(path, tries - 1)
      true -> flunk("#{path} never written")
    end
  end

  @tag :examples
  test "find picks github-link-preview's handler for issues and pulls only" do
    {:ok, _} = Install.link(Path.join(PluginDirs.examples(), "github-link-preview"), true)
    plugins = Registry.plugins()

    for url <- ~w(https://github.com/o/r/issues/1 https://github.com/o/r/pull/2/) do
      assert {%{"plugin_id" => "examples.github-link-preview"}, %{"id" => "github-issue-or-pr"},
              %{"id" => "open"}} = Links.find(plugins, url)
    end

    assert Links.find(plugins, "https://github.com/o/r/tree/main") == nil
  end

  test "find skips disabled plugins and takes the first plugin by id", %{base: base} do
    handler_plugin(base, "b.p", "^https://")
    handler_plugin(base, "a.p", "^https://e")
    handler_plugin(base, "0.p", "^https://", false)
    assert {%{"plugin_id" => "a.p"}, _, _} = Links.find(Registry.plugins(), "https://e.com")
    assert {%{"plugin_id" => "b.p"}, _, _} = Links.find(Registry.plugins(), "https://x.com")
  end

  test "modifiers keep shift, alt, ctrl in herdr's order and drop the rest" do
    assert Links.modifiers([:ctrl, :alt]) == ["alt", "ctrl"]
    assert Links.modifiers([:super, :shift, :ctrl, :meta]) == ["shift", "ctrl"]
    assert Links.modifiers(["ctrl", "shift"]) == ["shift", "ctrl"]
    assert Links.modifiers([]) == []
  end

  test "dispatch runs the handler's action with the link env", %{base: base} do
    out = handler_plugin(base, "t.p", "^https://e\\\\.com/")
    start_runtime()
    {:ok, _, _} = Store.request({HerdrServer.App.Commands, :noop, []})

    assert Links.dispatch("https://e.com/a", [:ctrl, :alt], 1) == :handled
    assert wait_file(out) == "https://e.com/a|h|alt,ctrl|p1"
    assert Links.dispatch("https://x.com/a", [:ctrl], 1) == :unhandled
  end

  test "dispatch without a running runtime is an error, not a fallback", %{base: base} do
    handler_plugin(base, "t.p", "^https://")
    assert {:error, _} = Links.dispatch("https://e.com/a", [:ctrl], 1)
  end

  describe "pane.link.activate" do
    setup %{base: base} do
      path = base <> "/a.sock"
      start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
      s = ApiClient.connect(path)
      %{"result" => _} = ApiClient.call(s, "workspace.list")
      %{s: s}
    end

    defp activate(s, params) do
      reply = ApiClient.call(s, "pane.link.activate", Map.merge(%{"pane_id" => "p1"}, params))

      with %{"result" => r} <- reply,
           do: assert(Spec.validate_result("pane.link.activate", r) == :ok)

      reply
    end

    defp osc8(uri) do
      {:ok, %{vt: vt, pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(1))
      :ok = Fake.Vt.set_link(vt, for(x <- 0..3, do: {x, 0}), 4, uri)
      Fake.Pty.output(pty, "link")
      wait_link()
    end

    defp wait_link(tries \\ 50) do
      row = with {_, rows, _} <- Rows.fetch(1), do: elem(rows, 0)

      cond do
        row && HerdrScene.Cell.decode_row(row) |> hd() |> Map.get(:link) == 4 -> :ok
        tries > 0 -> Process.sleep(10) && wait_link(tries - 1)
        true -> flunk("link never reached the rows")
      end
    end

    test "an osc 8 link a handler matches runs it", %{s: s, base: base} do
      out = handler_plugin(base, "t.p", "^ssh://")
      start_runtime()
      osc8("ssh://h/x")

      assert %{"result" => %{"url" => "ssh://h/x", "handled" => true}} =
               activate(s, %{"col" => 3, "viewport_row" => 0, "modifiers" => ["ctrl"]})

      assert wait_file(out) == "ssh://h/x|h|ctrl|p1"
    end

    test "an unhandled link answers handled false; no link answers url nil", %{s: s} do
      start_runtime()
      osc8("https://e.com/z")

      assert %{"result" => %{"url" => "https://e.com/z", "handled" => false}} =
               activate(s, %{"col" => 3, "viewport_row" => 0})

      assert %{"result" => %{"url" => nil, "handled" => false}} =
               activate(s, %{"col" => 9, "viewport_row" => 0})
    end

    test "an unknown pane is not_found; a failed launch is failed", %{s: s, base: base} do
      assert %{"error" => %{"code" => "not_found"}} =
               activate(s, %{"pane_id" => "p99", "col" => 0, "viewport_row" => 0})

      handler_plugin(base, "t.p", "^https://")
      osc8("https://e.com/z")

      assert %{"error" => %{"code" => "failed", "data" => %{"reason" => "plugin_link_failed"}}} =
               activate(s, %{"col" => 3, "viewport_row" => 0})
    end
  end
end
