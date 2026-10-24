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
  def handle(method, _params, _ctx), do: {:error, :not_available, "#{method} is not served yet"}
end
