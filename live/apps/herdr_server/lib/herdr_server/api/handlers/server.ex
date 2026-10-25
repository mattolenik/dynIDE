defmodule HerdrServer.Api.Handlers.Server do
  @moduledoc """
  Handlers for the `server` and `reload` API groups: `ping`, `api.schema`,
  `server.status`, `reload.rollback`, `reload.test_on_save`. Reload verbs answer
  `not_available` when the `HerdrReload` pipeline is disabled.
  """

  alias HerdrReload.TestGate
  alias HerdrScene.Protocol
  alias HerdrServer.Api.{Listener, Spec}
  alias HerdrServer.App.Store

  @spec ping() :: {:ok, map()}
  def ping, do: {:ok, %{type: "pong", version: version(), gen: gen()}}

  @spec schema() :: {:ok, map()}
  def schema, do: {:ok, %{type: "api_schema", methods: Enum.map(Spec.methods(), &method/1)}}

  @spec status() :: {:ok, map()}
  def status do
    {workspaces, panes} =
      case Store.snapshot() do
        nil -> {0, 0}
        app -> {length(app.session.workspaces), map_size(app.session.panes)}
      end

    handoff = :persistent_term.get(Protocol.handoff_key(), nil)

    {:ok,
     %{
       type: "server_status",
       gen: gen(),
       os_pid: String.to_integer(System.pid()),
       reload_enabled: reload?(),
       test_on_save: if(reload?(), do: Atom.to_string(TestGate.mode())),
       handoff: if(handoff, do: to_string(handoff)),
       workspaces: workspaces,
       panes: panes,
       api_conns: Listener.conns()
     }}
  end

  @spec rollback(map(), map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def rollback(params, ctx) do
    if reload?() do
      n = Map.get(params, :n, 1)

      case call_rollback(ctx.reload_server, n, ctx.rollback_timeout_ms) do
        {:ok, ids} -> {:ok, %{type: "reload_rollback", batches: ids}}
        {:error, _, _} = e -> e
      end
    else
      disabled()
    end
  end

  # Every exit of the call is an answer here, never a Guard failure: a Guard failure
  # that rolled back a batch would re-run the handler, and so the rollback, again.
  defp call_rollback(server, n, timeout) do
    HerdrReload.Server.rollback(server, n, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout, "rollback timed out"}

    :exit, {:noproc, _} ->
      {:error, :failed, "the reload server is not running"}

    :exit, reason ->
      {:error, :failed, "rollback failed: " <> String.slice(inspect(reason), 0, 200)}
  end

  @spec test_on_save(map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def test_on_save(params) do
    if reload?() do
      case params[:mode] do
        "on" -> TestGate.set_mode(:gate)
        "off" -> TestGate.set_mode(:off)
        nil -> :ok
      end

      {:ok, %{type: "test_on_save", mode: Atom.to_string(TestGate.mode())}}
    else
      disabled()
    end
  end

  defp disabled, do: {:error, :not_available, "reload is disabled"}

  defp reload?, do: Application.get_env(:herdr_reload, HerdrReload, [])[:enabled] == true

  @doc false
  def version, do: to_string(Application.spec(:herdr_server, :vsn) || "0")

  @doc false
  def gen do
    case Integer.parse(System.get_env("HERDR_LIVE_GEN") || "0") do
      {n, ""} -> n
      _ -> 0
    end
  end

  # --- api.schema: the spec as JSON ------------------------------------------

  defp method(m) do
    %{
      name: m.name,
      group: m.group,
      summary: m.summary,
      params: Enum.map(m.params, &param/1),
      result: m.result,
      errors: m.errors,
      cli: m.cli
    }
  end

  defp param(p) do
    base = %{name: p.name, type: type(p.type), required: p.required, doc: p.doc}
    if p[:min_items], do: Map.put(base, :min_items, p.min_items), else: base
  end

  defp type(t) when is_atom(t), do: %{kind: t}
  defp type({:integer, min, max}), do: %{kind: :integer, min: min, max: max}
  defp type({:number, min, max}), do: %{kind: :number, min: min, max: max}
  defp type({:enum, values}), do: %{kind: :enum, values: values}
  defp type({:list, t}), do: %{kind: :list, of: type(t)}
  defp type({:map, t}), do: %{kind: :map, of: type(t)}
  defp type({:object, ps}), do: %{kind: :object, params: Enum.map(ps, &param/1)}
end
