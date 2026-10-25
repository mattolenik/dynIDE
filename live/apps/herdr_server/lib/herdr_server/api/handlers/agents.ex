defmodule HerdrServer.Api.Handlers.Agents do
  @moduledoc """
  Handlers for `agent.*`, `server.agent_manifests`, `server.reload_agent_manifests`,
  `pane.report_agent` and `pane.release_agent`.

  A target is resolved by `Api.AgentView.resolve/2`. `agent.read`, `prompt` and
  `send_keys` are `pane.read`, `pane.run` and `pane.send_keys` on the target's pane
  (`Handlers.PaneIo`). `agent.wait` polls like `pane.wait_for_output`: it answers at once
  when the agent's status is in `until`, else `{:continue, {__MODULE__, :poll_wait, ...}}`.
  """

  alias HerdrServer.Api.{AgentView, Ids}
  alias HerdrServer.Api.Handlers.{PaneIo, Topology}
  alias HerdrServer.App.Store
  alias HerdrServer.Detect.{Engine, Manifests, Poller}
  alias HerdrServer.Pane.Facts

  # the Spec's report states; never `String.to_atom` on input
  @states %{
    "idle" => :idle,
    "working" => :working,
    "blocked" => :blocked,
    "unknown" => :unknown
  }

  @type reply ::
          {:ok, map()}
          | {:error, atom(), String.t()}
          | {:error, atom(), String.t(), map()}
          | {:continue, {module(), atom(), list()}}

  @spec handle(String.t(), map()) :: reply()
  def handle("agent.list", _p) do
    app = Topology.app!()
    {:ok, %{type: "agent_list", agents: Enum.map(AgentView.agent_ids(app), &info(app, &1))}}
  end

  def handle("agent.get", %{target: t}) do
    app = Topology.app!()

    with {:ok, id} <- AgentView.resolve(app, t),
         do: {:ok, %{type: "agent_info", agent: info(app, id)}}
  end

  def handle("agent.read", %{target: t} = p) do
    with {:ok, id} <- AgentView.resolve(Topology.app!(), t),
         {:ok, r} <- PaneIo.handle("pane.read", p |> Map.delete(:target) |> Map.put(:pane_id, id)) do
      {:ok, %{type: "agent_read", target: t, text: r.text}}
    end
  end

  def handle("agent.prompt", %{target: t, text: text}),
    do: on_pane(t, "pane.run", %{command: text})

  def handle("agent.send_keys", %{target: t, keys: keys}),
    do: on_pane(t, "pane.send_keys", %{keys: keys})

  def handle("agent.explain", %{target: t} = p)
      when not is_map_key(p, :agent) and not is_map_key(p, :text) do
    with {:ok, id} <- AgentView.resolve(Topology.app!(), t),
         do: explain_pane(id, p[:verbose] || false)
  end

  def handle("agent.explain", %{agent: label, text: text} = p)
      when not is_map_key(p, :target) do
    input = %{screen: text, osc_title: "", osc_progress: ""}
    explained(Engine.explain(label, Manifests.get(label), input), p[:verbose] || false)
  end

  def handle("agent.explain", _p),
    do: {:error, :invalid_params, "give either target, or both agent and text"}

  def handle("server.agent_manifests", _p),
    do: {:ok, %{type: "agent_manifests", manifests: Manifests.summaries()}}

  def handle("server.reload_agent_manifests", _p),
    do: {:ok, %{type: "agent_manifests", manifests: Manifests.reload()}}

  def handle("pane.report_agent", %{pane_id: id} = p) do
    hook = %{source: p.source, agent: p.agent, state: Map.fetch!(@states, p.state), seq: p[:seq]}
    id |> Poller.report(hook) |> hooked(id)
  end

  def handle("pane.release_agent", %{pane_id: id} = p),
    do: id |> Poller.release(p.source, p.agent) |> hooked(id)

  @doc """
  `agent.wait`: see the moduledoc. The continuation holds only data (the pane id, the
  wanted states and the deadline), so a reload moves a running wait onto new code.
  """
  @spec wait(map(), map()) :: reply()
  def wait(%{target: t} = p, _ctx) do
    with {:ok, id} <- AgentView.resolve(Topology.app!(), t) do
      deadline = p[:timeout_ms] && System.monotonic_time(:millisecond) + p.timeout_ms
      poll_wait(%{id: id, target: t, until: p[:until] || ["idle"]}, deadline, nil)
    end
  end

  @doc false
  # One poll of a running wait (see `wait/2`).
  @spec poll_wait(map(), integer() | nil, map() | nil) :: reply()
  def poll_wait(w, deadline, _ctx) do
    app = Store.snapshot()

    case app && info(app, w.id) do
      nil ->
        {:error, :not_found, "agent #{w.target} is gone"}

      %{agent_status: s} = agent ->
        cond do
          s in w.until -> {:ok, %{type: "agent_wait", agent: agent}}
          deadline && System.monotonic_time(:millisecond) >= deadline -> timeout(w)
          true -> {:continue, {__MODULE__, :poll_wait, [w, deadline]}}
        end
    end
  end

  defp timeout(w),
    do: {:error, :timeout, "agent #{w.target} did not reach #{Enum.join(w.until, ", ")} in time"}

  # --- helpers ---

  defp info(app, id), do: AgentView.info(app, id, Facts.get(id), Facts.agent(id))

  defp on_pane(target, method, params) do
    with {:ok, id} <- AgentView.resolve(Topology.app!(), target),
         do: PaneIo.handle(method, Map.put(params, :pane_id, id))
  end

  # herdr: a hook holding the state answers its own explanation, with no screen evaluation
  defp explain_pane(id, verbose) do
    case {Facts.agent(id), Poller.detect_now(id)} do
      {%{skipped: true} = row, {:ok, _}} -> explained(hooked_explain(row), verbose)
      {_, {:ok, %{agent: nil}}} -> {:error, :failed, "pane has no detected agent"}
      {_, {:ok, d}} -> explained(Engine.explain(d.agent, d.entry, d.input), verbose)
      {_, {:error, :not_found}} -> {:error, :not_found, "no such pane #{Ids.pane(id)}"}
      {_, {:error, :failed}} -> {:error, :failed, "could not read the pane's screen"}
    end
  end

  defp hooked_explain(row) do
    %{
      "agent" => row.agent || "unknown",
      "state" => Atom.to_string(row.state),
      "manifest_source" => nil,
      "manifest_version" => nil,
      "matched_rule" => nil,
      "visible_idle" => false,
      "visible_blocker" => false,
      "visible_working" => false,
      "screen_detection_skipped" => true,
      "screen_detection_skip_reason" => "full_lifecycle_hook_authority",
      "skip_state_update" => false,
      "skipped_update_reason" => nil,
      "fallback_reason" => nil,
      "warning" => nil,
      "evaluated_rules" => [],
      "limit_hits" => 0
    }
  end

  defp explained(map, verbose),
    do:
      {:ok, %{type: "agent_explain", agent: map, explanation: Engine.explain_text(map, verbose)}}

  defp hooked(:ok, _id), do: {:ok, %{type: "ok"}}
  defp hooked({:error, :not_found}, id), do: {:error, :not_found, "no such pane #{Ids.pane(id)}"}
  # a guarded detection call crashed: a server fault, not a request the caller can fix
  defp hooked({:error, :failed}, _id), do: {:error, :internal, "agent detection failed"}
end
