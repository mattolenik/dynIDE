defmodule HerdrServer.Api.ConformanceTest do
  @moduledoc """
  One test per (method, declared error code) in `Api.Spec`: each produces that code over
  the socket. A code a method declares but cannot answer has no `produce/3` clause and
  fails here, so the Spec's error lists stay what the handlers really return.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Events, Listener, Spec}
  alias HerdrServer.App.{Store, Worktrees}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Plugins.{Install, Menu, Paths, Runtime}
  alias HerdrServer.Test.{ApiClient, PluginDirs}

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    dir = Path.join(System.tmp_dir!(), "hlk#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!(Events)
    %{path: Path.join(dir, "a.sock")}
  end

  for m <- Spec.methods(), code <- m.errors do
    @tag method: m.name, code: code
    test "#{m.name} answers #{code}", %{method: method, code: code} = ctx do
      reply = produce(method, code, ctx)
      assert %{"error" => %{"code" => got}} = reply, inspect(reply)
      assert got == Atom.to_string(code), inspect(reply)
    end
  end

  # --- setup helpers ---

  defp listen(ctx, opts \\ []) do
    start_supervised!({Listener, opts ++ [path: ctx.path, reload_server: :no_reload_server]})
    s = ApiClient.connect(ctx.path)
    # initialises the app: w1, w1:t1, p1
    %{"result" => _} = ApiClient.call(s, "workspace.list")
    s
  end

  defp reload_enabled do
    old = Application.get_env(:herdr_reload, HerdrReload, [])
    Application.put_env(:herdr_reload, HerdrReload, Keyword.put(old, :enabled, true))
    on_exit(fn -> Application.put_env(:herdr_reload, HerdrReload, old) end)
  end

  defp plugin_runtime do
    start_supervised!({Task.Supervisor, name: HerdrServer.Plugins.Tasks})
    start_supervised!(Runtime)
    on_exit(fn -> Menu.put([]) end)
  end

  defp pty do
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(1))
    pty
  end

  defp params(method, fill) do
    {:ok, m} = Spec.fetch(method)
    for p <- m.params, p.required or Map.has_key?(fill, p.name), into: %{}, do: value(p, fill)
  end

  defp value(%{name: name} = p, fill) do
    case fill do
      %{^name => v} -> {name, v}
      _ -> {name, default(p.type)}
    end
  end

  defp default(:workspace_id), do: "w1"
  defp default(:tab_id), do: "w1:t1"
  defp default(:pane_id), do: "p1"
  defp default(:string), do: "x"
  defp default({:integer, min, _}), do: min
  defp default({:enum, [v | _]}), do: v
  defp default({:list, :string}), do: ["a"]
  defp default({:list, {:object, _}}), do: [%{"type" => "pane.created"}]
  defp default({:map, _}), do: %{"k" => "v"}

  defp call(s, method, fill \\ %{}), do: ApiClient.call(s, method, params(method, fill))

  # --- one clause per kind of (method, code) ---

  defp produce(method, :invalid_params, ctx),
    do: ApiClient.call(listen(ctx), method, Map.put(params(method, %{}), "bogus", 1))

  defp produce("reload." <> _ = method, :not_available, ctx), do: call(listen(ctx), method)

  defp produce("reload.rollback", :failed, ctx) do
    reload_enabled()
    call(listen(ctx, reload_server: :no_such_server), "reload.rollback")
  end

  defp produce("reload.rollback", :timeout, ctx) do
    reload_enabled()
    hung = spawn_link(fn -> Process.sleep(:infinity) end)
    call(listen(ctx, reload_server: hung, rollback_timeout_ms: 50), "reload.rollback")
  end

  defp produce("agent." <> _ = method, :not_available, ctx), do: call(listen(ctx), method)

  defp produce(method, :not_available, ctx)
       when method in ~w(server.agent_manifests server.reload_agent_manifests
                         pane.report_agent pane.release_agent),
       do: call(listen(ctx), method)

  defp produce(method, :failed, ctx) when method in ~w(plugin.install plugin.link) do
    base = PluginDirs.use_tmp()
    call(listen(ctx), method, %{"source" => base <> "/none", "path" => base <> "/none"})
  end

  defp produce(method, :not_found, ctx)
       when method in ~w(plugin.uninstall plugin.enable plugin.disable) do
    PluginDirs.use_tmp()
    call(listen(ctx), method)
  end

  # the registry cannot be written: its tmp file's name is taken by a directory
  defp produce(method, :failed, ctx)
       when method in ~w(plugin.uninstall plugin.enable plugin.disable) do
    base = PluginDirs.use_tmp()
    {:ok, _} = Install.link(PluginDirs.plugin(base <> "/p", "x"), true)
    File.mkdir_p!(Paths.registry() <> ".tmp")
    call(listen(ctx), method)
  end

  defp produce("plugin.config_dir", :failed, ctx) do
    PluginDirs.use_tmp()
    File.mkdir_p!(Paths.config_dir())
    File.write!(Path.join(Paths.config_dir(), "plugins"), "")
    call(listen(ctx), "plugin.config_dir")
  end

  defp produce("plugin.action.invoke", :not_found, ctx) do
    PluginDirs.use_tmp()
    plugin_runtime()
    call(listen(ctx), "plugin.action.invoke", %{"action_id" => "none"})
  end

  defp produce("plugin.action.invoke", :failed, ctx) do
    base = PluginDirs.use_tmp()
    toml = "[[actions]]\nid = \"go\"\ntitle = \"Go\"\ncommand = [\"true\"]\n"
    {:ok, _} = Install.link(PluginDirs.plugin(base <> "/p", "x", toml), false)
    plugin_runtime()
    call(listen(ctx), "plugin.action.invoke", %{"action_id" => "go"})
  end

  defp produce("plugin.pane.open", :not_found, ctx) do
    PluginDirs.use_tmp()
    call(listen(ctx), "plugin.pane.open")
  end

  defp produce("plugin.pane.open", :failed, ctx) do
    base = PluginDirs.use_tmp()
    toml = "[[panes]]\nid = \"p\"\ntitle = \"P\"\ncommand = [\"sh\"]\n"
    {:ok, _} = Install.link(PluginDirs.plugin(base <> "/p", "x", toml), false)
    call(listen(ctx), "plugin.pane.open", %{"plugin_id" => "x", "entrypoint" => "p"})
  end

  # a second popup while the first is open (herdr's ui_busy)
  defp produce("plugin.pane.open", :ui_busy, ctx) do
    base = PluginDirs.use_tmp()
    toml = "[[panes]]\nid = \"p\"\ntitle = \"P\"\nplacement = \"popup\"\ncommand = [\"sh\"]\n"
    {:ok, _} = Install.link(PluginDirs.plugin(base <> "/p", "x", toml), true)
    s = listen(ctx)
    params = %{"plugin_id" => "x", "entrypoint" => "p"}
    %{"result" => _} = ApiClient.call(s, "plugin.pane.open", params)
    reply = ApiClient.call(s, "plugin.pane.open", params)
    %{"error" => %{"data" => %{"reason" => "ui_busy"}}} = reply
    reply
  end

  # p1 is not a plugin pane
  defp produce(method, :not_found, ctx) when method in ~w(plugin.pane.focus plugin.pane.close),
    do: call(listen(ctx), method)

  # without a plugin runtime
  defp produce("plugin." <> _ = method, :not_available, ctx), do: call(listen(ctx), method)

  # a handler matches the text url at (0, 0), but no plugin runtime runs to launch it
  defp produce("pane.link.activate", :failed, ctx) do
    base = PluginDirs.use_tmp()

    toml = """
    [[actions]]
    id = "go"
    title = "Go"
    command = ["true"]
    [[link_handlers]]
    id = "h"
    title = "H"
    pattern = "^https://"
    action = "go"
    """

    {:ok, _} = Install.link(PluginDirs.plugin(base <> "/p", "x", toml), true)
    s = listen(ctx)
    Fake.Pty.output(pty(), "https://e.com/z")

    Enum.find_value(1..50, fn _ ->
      case call(s, "pane.link.activate") do
        %{"result" => %{"url" => nil}} -> Process.sleep(10) && nil
        reply -> reply
      end
    end)
  end

  defp produce("events.subscribe", :not_found, ctx) do
    subs = [%{"type" => "pane.created", "pane_id" => "p99"}]
    call(listen(ctx), "events.subscribe", %{"subscriptions" => subs})
  end

  defp produce("events.subscribe", :not_available, ctx) do
    s = listen(ctx)
    stop_supervised!(Events)
    call(s, "events.subscribe")
  end

  defp produce("events.subscribe", :events_lost, ctx) do
    s = listen(ctx)
    %{"result" => %{"type" => "subscription_started"}} = call(s, "events.subscribe")
    Process.exit(Process.whereis(Events), :kill)
    ApiClient.recv_line(s)
  end

  # over the 32-token cap
  defp produce(method, :failed, ctx)
       when method in ~w(pane.report_metadata workspace.report_metadata) do
    s = listen(ctx)
    for i <- 0..1, do: call(s, method, %{"tokens" => Map.new(1..16, &{"k#{i}_#{&1}", "v"})})
    call(s, method, %{"tokens" => %{"one_more" => "v"}})
  end

  defp produce("workspace.close", :failed, ctx), do: call(listen(ctx), "workspace.close")

  # an insert_index past the end
  defp produce(method, :failed, ctx) when method in ~w(tab.move workspace.move),
    do: call(listen(ctx), method, %{"insert_index" => 99})

  defp produce("pane.split", :failed, ctx) do
    s = listen(ctx)

    Enum.find_value(1..12, fn _ ->
      case call(s, "pane.split", %{"direction" => "down", "focus" => true}) do
        %{"error" => _} = e -> e
        %{"result" => _} -> nil
      end
    end)
  end

  defp produce(method, :backpressure, ctx)
       when method in ~w(pane.send_text pane.send_keys) do
    s = listen(ctx)
    Fake.Pty.set_backpressure(pty(), true)
    call(s, method)
  end

  defp produce(method, :failed, ctx) when method in ~w(pane.send_text pane.send_keys) do
    s = listen(ctx)
    Fake.Pty.fail_once_after(pty(), 0, :too_large)
    call(s, method)
  end

  defp produce("pane.wait_for_output", :timeout, ctx),
    do: call(listen(ctx), "pane.wait_for_output", %{"match" => "zzz", "timeout_ms" => 100})

  defp produce("pane.wait_for_output", :not_found, ctx),
    do: call(listen(ctx), "pane.wait_for_output", %{"pane_id" => "p99", "match" => "x"})

  # git's own error: a cwd outside any repo (never a real checkout: remove would act on it)
  defp produce("worktree.remove", :failed, ctx) do
    s = listen(ctx)
    {:ok, _, _} = Store.request({Worktrees, :open, [Path.dirname(ctx.path), "plain", false]})
    call(s, "worktree.remove", %{"workspace_id" => "w2"})
  end

  defp produce("worktree." <> _ = method, :failed, ctx),
    do: call(listen(ctx), method, %{"cwd" => Path.dirname(ctx.path), "branch" => "b"})

  defp produce("worktree.open", :not_found, ctx),
    do: call(listen(ctx), "worktree.open", %{"workspace_id" => "w9", "branch" => "b"})

  defp produce("popup.close", :not_found, ctx), do: call(listen(ctx), "popup.close")
  defp produce(method, :not_found, ctx), do: call(listen(ctx), method, missing(method))

  # params naming an id that does not exist: the method's own id param, else its scope
  defp missing(method) do
    {:ok, m} = Spec.fetch(method)
    names = Enum.map(m.params, & &1.name)

    cond do
      "pane_id" in names -> %{"pane_id" => "p99"}
      "caller_pane_id" in names -> %{"caller_pane_id" => "p99"}
      "tab_id" in names -> %{"tab_id" => "w1:t9"}
      "workspace_id" in names -> %{"workspace_id" => "w9"}
      "name" in names -> %{"name" => "nope"}
    end
  end
end
