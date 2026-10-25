defmodule HerdrServer.Api.Router do
  @moduledoc """
  Dispatches a validated API request to its handler. `HerdrServer.Api.Conn` calls
  `handle/3` through `HerdrReload.Guard`, only for methods `Api.Spec` knows, with params
  already validated (atom keys). `ctx` is `%{conn: pid, socket: socket, reload_server: server,
  rollback_timeout_ms: n}`. `events.subscribe` answers `{:subscribe, filters}`; a wait that has not finished answers
  `{:continue, {m, f, a}}` (`Api.Conn` polls it).
  """

  alias HerdrServer.Api.{Events, Handlers}

  @type sub :: map()
  @type reply ::
          {:ok, map()}
          | {:error, atom(), String.t()}
          | {:error, atom(), String.t(), map()}
          | {:subscribe, [sub()]}
          | {:continue, {module(), atom(), list()}}

  @spec handle(String.t(), map(), map()) :: reply()
  def handle("ping", _params, _ctx), do: Handlers.Server.ping()
  def handle("api.schema", _params, _ctx), do: Handlers.Server.schema()
  def handle("server.status", _params, _ctx), do: Handlers.Server.status()

  def handle(method, params, _ctx) when method in ~w(session.list session.get client.list),
    do: Handlers.Session.handle(method, params)

  def handle("session.snapshot", _params, _ctx), do: Handlers.Session.snapshot()

  def handle("reload.rollback", params, ctx), do: Handlers.Server.rollback(params, ctx)
  def handle("reload.test_on_save", params, _ctx), do: Handlers.Server.test_on_save(params)

  def handle("workspace." <> _ = method, params, _ctx),
    do: Handlers.Topology.handle(method, params)

  def handle("tab." <> _ = method, params, _ctx), do: Handlers.Topology.handle(method, params)

  def handle(method, params, _ctx)
      when method in ~w(pane.list pane.get pane.current pane.split pane.close pane.focus
                        pane.zoom pane.layout pane.process_info pane.rename
                        pane.focus_direction pane.swap pane.resize),
      do: Handlers.Topology.handle(method, params)

  def handle("pane.wait_for_output", params, ctx),
    do: Handlers.PaneIo.wait_for_output(params, ctx)

  def handle(method, params, _ctx)
      when method in ~w(pane.send_text pane.send_keys pane.run pane.read),
      do: Handlers.PaneIo.handle(method, params)

  def handle("notification.show", params, _ctx), do: Handlers.Notification.show(params)

  def handle("client.window_title." <> _ = method, params, _ctx),
    do: Handlers.Client.handle(method, params)

  def handle("events.subscribe", params, ctx), do: Events.request(params, ctx.conn)

  def handle("agent." <> _ = method, params, _ctx), do: Handlers.Agents.handle(method, params)

  def handle(method, params, _ctx)
      when method in ~w(server.agent_manifests server.reload_agent_manifests
                        pane.report_agent pane.release_agent),
      do: Handlers.Agents.handle(method, params)

  def handle("plugin." <> _ = method, params, _ctx), do: Handlers.Plugins.handle(method, params)

  def handle("worktree." <> _ = method, params, _ctx),
    do: Handlers.Worktrees.handle(method, params)

  def handle("pane.link.activate", params, _ctx),
    do: Handlers.Plugins.handle("pane.link.activate", params)

  def handle(method, _params, _ctx), do: {:error, :not_available, "#{method} is not served yet"}
end
