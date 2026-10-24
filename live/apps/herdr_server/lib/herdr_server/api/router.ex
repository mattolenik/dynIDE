defmodule HerdrServer.Api.Router do
  @moduledoc """
  Dispatches a validated API request to its handler. `HerdrServer.Api.Conn` calls
  `handle/3` through `HerdrReload.Guard`, only for methods `Api.Spec` knows, with params
  already validated (atom keys). `ctx` is `%{conn: pid, reload_server: server,
  rollback_timeout_ms: n}`.
  """

  alias HerdrServer.Api.Handlers

  @type sub :: map()
  @type reply ::
          {:ok, map()}
          | {:error, atom(), String.t()}
          | {:error, atom(), String.t(), map()}
          | {:subscribe, [sub()]}

  @spec handle(String.t(), map(), map()) :: reply()
  def handle("ping", _params, _ctx), do: Handlers.Server.ping()
  def handle("api.schema", _params, _ctx), do: Handlers.Server.schema()
  def handle("server.status", _params, _ctx), do: Handlers.Server.status()
  def handle("reload.rollback", params, ctx), do: Handlers.Server.rollback(params, ctx)
  def handle("reload.test_on_save", params, _ctx), do: Handlers.Server.test_on_save(params)

  def handle("workspace." <> _ = method, params, _ctx),
    do: Handlers.Topology.handle(method, params)

  def handle("tab." <> _ = method, params, _ctx), do: Handlers.Topology.handle(method, params)

  def handle(method, params, _ctx)
      when method in ~w(pane.list pane.get pane.current pane.split pane.close pane.focus
                        pane.layout pane.process_info),
      do: Handlers.Topology.handle(method, params)

  def handle(method, params, _ctx)
      when method in ~w(pane.send_text pane.send_keys pane.run pane.read pane.wait_for_output),
      do: Handlers.PaneIo.handle(method, params)

  def handle("agent." <> _ = method, params, _ctx), do: Handlers.Agents.handle(method, params)

  def handle(method, _params, _ctx), do: {:error, :not_available, "#{method} is not served yet"}
end
