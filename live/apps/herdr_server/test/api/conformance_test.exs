defmodule HerdrServer.Api.ConformanceTest do
  @moduledoc """
  One test per (method, declared error code) in `Api.Spec`: each produces that code over
  the socket. A code a method declares but cannot answer has no `produce/3` clause and
  fails here, so the Spec's error lists stay what the handlers really return.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Events, Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Test.ApiClient

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
  defp default({:enum, [v | _]}), do: v
  defp default({:list, :string}), do: ["a"]
  defp default({:list, {:object, _}}), do: [%{"type" => "pane.created"}]

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

  defp produce("workspace.close", :failed, ctx), do: call(listen(ctx), "workspace.close")

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
       when method in ~w(pane.send_text pane.send_keys pane.run) do
    s = listen(ctx)
    Fake.Pty.set_backpressure(pty(), true)
    call(s, method)
  end

  defp produce(method, :failed, ctx) when method in ~w(pane.send_text pane.send_keys pane.run) do
    s = listen(ctx)
    # pane.run: the command is written, the Enter after it is refused
    Fake.Pty.fail_once_after(pty(), if(method == "pane.run", do: 1, else: 0), :too_large)
    call(s, method)
  end

  defp produce("pane.wait_for_output", :timeout, ctx),
    do: call(listen(ctx), "pane.wait_for_output", %{"match" => "zzz", "timeout_ms" => 100})

  defp produce("pane.wait_for_output", :not_found, ctx),
    do: call(listen(ctx), "pane.wait_for_output", %{"pane_id" => "p99", "match" => "x"})

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
    end
  end
end
