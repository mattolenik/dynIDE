defmodule HerdrServer.Plugins.Runtime do
  @moduledoc """
  Runs plugin commands: actions (API, keybinds, menus), startup hooks once at start, and
  event hooks on API events. Commands run in `HerdrServer.Plugins.Tasks` children calling
  `Plugins.Command.run/4`; this process only counts them (at most 32 in flight) and keeps
  herdr's command log (`PluginCommandLogInfo`, a ring of 200).

  The registry is re-read at each invoke and event (herdr does the same), so a manifest
  edited on disk applies on the next run. ponytail: cache if a hook storm shows.

  Every 2 s and on `refresh/0` (sent by `Registry.update/1`) it rebuilds the
  `Plugins.Menu` catalog and subscribes to `Api.Events` for exactly the hooked event
  types; without hooks it unsubscribes, so there is no hub cost (nothing when the hub is
  not running). Startup hooks run once per VM, not again when the Runtime restarts.

  A failing keybind or menu invocation (not found, disabled, limit, start error) is an
  `Alert`; a command exiting non-zero is only logged `failed`. Startup and event hook
  invocations, hook passes and refreshes run through `HerdrReload.Guard`, so a failure
  never crashes the Runtime (which would drop its in-flight count) or stops the server.
  """
  use GenServer

  require Logger

  alias HerdrReload.Guard
  alias HerdrServer.Api.Events
  alias HerdrServer.App.Store
  alias HerdrServer.Plugins.{Alert, Command, Context, Env, Manifest, Menu, Paths, Registry}

  @max_in_flight 32
  @log_limit 200
  @refresh_ms 2_000
  # set once this VM ran its startup hooks: a restarted Runtime skips them (a new VM, as
  # after a handoff takeover, runs them again, as herdr does)
  @startup_ran {__MODULE__, :startup_ran}

  defstruct logs: [], next_log: 1, in_flight: %{}, hooked: [], events: nil, tasks: nil

  @type log :: %{String.t() => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs action `id` (qualified, or local when unique; `plugin_id` narrows it) with the
  context built from the current app, `overrides` (herdr context fields) winning.
  """
  @spec invoke(String.t(), String.t() | nil, map(), String.t()) ::
          {:ok, %{action: map(), context: map(), log: log()}} | {:error, String.t(), String.t()}
  def invoke(id, plugin_id, overrides, source),
    do: GenServer.call(__MODULE__, {:invoke, id, plugin_id, overrides, source}, 15_000)

  @doc "The newest `limit` records (of `plugin_id`, or all), oldest first."
  @spec logs(String.t() | nil, pos_integer()) :: [log()]
  def logs(plugin_id, limit), do: GenServer.call(__MODULE__, {:logs, plugin_id, limit})

  @spec running?() :: boolean()
  def running?, do: GenServer.whereis(__MODULE__) != nil

  @doc "Asks a running Runtime to re-read the registry now."
  @spec refresh() :: :ok
  def refresh do
    if pid = GenServer.whereis(__MODULE__), do: send(pid, :refresh)
    :ok
  end

  @doc "herdr's `PluginActionInfo` for every action of loadable plugins, by qualified id."
  @spec actions(String.t() | nil) :: [map()]
  def actions(plugin_id \\ nil) do
    for p <- Registry.plugins(),
        p["error"] == nil and plugin_id in [nil, p["plugin_id"]],
        a <- p["actions"],
        do: action_info(p, a)
  end

  # --- callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{tasks: opts[:tasks] || HerdrServer.Plugins.Tasks}
    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state) do
    state = Map.merge(%__MODULE__{}, state)

    state =
      if :persistent_term.get(@startup_ran, false) do
        state
      else
        :persistent_term.put(@startup_ran, true)
        guarded(state, :run_startup, [])
      end

    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, guarded(state, :run_sync, [])}
  end

  @impl true
  def handle_call({:invoke, id, plugin_id, overrides, source}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    args = [state, id, plugin_id, overrides, source]
    failed = fn msg -> {{:error, "plugin_runtime_failed", msg}, state} end
    {reply, state} = guard(:run_invoke, args, failed)
    {:reply, reply, state}
  end

  def handle_call({:logs, plugin_id, limit}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    logs =
      for(l <- state.logs, plugin_id in [nil, l["plugin_id"]], do: l)
      |> Enum.take(limit)
      |> Enum.reverse()
      |> Enum.map(&public/1)

    {:reply, logs, state}
  end

  @impl true
  # a keybind or menu item, through the Store's `{:plugin, msg}` effect
  def handle_info({{:invoke, id, %{source: source} = meta}, _origin}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, guarded(state, :run_bound, [id, source, meta[:target]])}
  end

  def handle_info({:api_event, event}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, guarded(state, :run_event, [event])}
  end

  def handle_info({ref, result}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    state = Map.merge(%__MODULE__{}, state)
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    state = Map.merge(%__MODULE__{}, state)

    result = %{
      exit_code: nil,
      stdout: "",
      stderr: "",
      error: "command crashed: #{inspect(reason)}"
    }

    {:noreply, finish(state, ref, result)}
  end

  # the event hub went away: subscribe again once it is back
  def handle_info({:DOWN, ref, :process, _, _}, %{events: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, %{state | events: nil, hooked: []}}
  end

  def handle_info(:tick, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, guarded(state, :run_sync, [])}
  end

  def handle_info(:refresh, state),
    do: {:noreply, guarded(Map.merge(%__MODULE__{}, state), :run_sync, [])}

  def handle_info(_msg, state), do: {:noreply, Map.merge(%__MODULE__{}, state)}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  # --- runs (public for Guard.run/4) ---

  @doc false
  def run_invoke(state, id, plugin_id, overrides, source) do
    extra = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)

    case run_action(state, id, plugin_id, source, nil, extra) do
      {:ok, reply, state} -> {{:ok, reply}, state}
      {:error, reason, msg, state} -> {{:error, reason, msg}, state}
    end
  end

  @doc false
  def run_startup(state) do
    ctx = Context.build(snapshot(), nil, "startup", %{"correlation_id" => "plugin.startup"})

    for p <- runnable(Registry.plugins()), s <- p["startup"], reduce: state do
      st ->
        if Manifest.platform_ok?(s["platforms"], p["platforms"]),
          do: elem(start(st, p, s["command"], ctx, %{event: "startup"}), 2),
          else: st
    end
  end

  @doc false
  def run_event(state, %{"event" => name} = event) do
    hooks =
      for p <- runnable(Registry.plugins()),
          h <- p["events"],
          h["on"] == name and Manifest.platform_ok?(h["platforms"], p["platforms"]),
          do: {p, h}

    if hooks == [] do
      state
    else
      ctx = Context.for_event(snapshot(), event)
      kind = %{event: name, event_json: JSON.encode!(event)}

      Enum.reduce(hooks, state, fn {p, h}, st ->
        elem(start(st, p, h["command"], ctx, kind), 2)
      end)
    end
  end

  def run_event(state, _event), do: state

  @doc false
  def run_bound(state, id, source, target) do
    app = snapshot()
    pane = target && Context.target_pane(app, target)

    case run_action(state, id, nil, source, pane, %{}, app) do
      {:ok, _reply, state} ->
        state

      {:error, _reason, msg, state} ->
        Alert.show("#{id}: #{msg}")
        state
    end
  end

  # --- internals ---

  defp run_action(state, id, plugin_id, source, pane, extra, app \\ :snapshot) do
    with {:ok, p, a} <- resolve(Registry.plugins(), id, plugin_id),
         :ok <- runnable?(p, a) do
      app = if app == :snapshot, do: snapshot(), else: app
      ctx = Context.build(app, pane, source, extra)

      case start(state, p, a["command"], ctx, %{action_id: a["id"]}) do
        {:ok, log, state} ->
          {:ok, %{action: action_info(p, a), context: ctx, log: public(log)}, state}

        {:error, reason, msg, state} ->
          {:error, reason, msg, state}
      end
    else
      {:error, reason, msg} -> {:error, reason, msg, state}
    end
  end

  defp resolve(plugins, id, nil) do
    matches =
      for p <- plugins,
          p["error"] == nil,
          a <- p["actions"],
          id in [a["id"], a["qualified_id"]],
          do: {p, a}

    case matches do
      [{p, a}] ->
        {:ok, p, a}

      [] ->
        {:error, "plugin_action_not_found", "plugin action not found"}

      _ ->
        {:error, "ambiguous_plugin_action",
         "plugin action id matches more than one action; include plugin_id"}
    end
  end

  defp resolve(plugins, id, plugin_id) do
    case Enum.find(plugins, &(&1["plugin_id"] == plugin_id)) do
      nil ->
        {:error, "plugin_not_found", "plugin not found"}

      %{"error" => e} when e != nil ->
        {:error, "plugin_manifest_unavailable", "plugin #{plugin_id} manifest is unavailable"}

      p ->
        case Enum.find(p["actions"], &(id in [&1["id"], &1["qualified_id"]])) do
          nil -> {:error, "plugin_action_not_found", "plugin action not found"}
          a -> {:ok, p, a}
        end
    end
  end

  defp runnable?(p, a) do
    cond do
      p["enabled"] != true ->
        {:error, "plugin_disabled", "plugin #{p["plugin_id"]} is disabled"}

      not Manifest.platform_ok?(a["platforms"], p["platforms"]) ->
        {:error, "platform_unsupported",
         "action '#{a["qualified_id"]}' does not support the current platform"}

      true ->
        :ok
    end
  end

  defp runnable(plugins),
    do: Enum.filter(plugins, &(&1["enabled"] == true and &1["error"] == nil))

  defp start(state, p, argv, ctx, kind) do
    id = p["plugin_id"]
    now = System.os_time(:millisecond)

    log = %{
      "log_id" => "plugin-log-#{state.next_log}",
      "plugin_id" => id,
      "action_id" => kind[:action_id],
      "event" => kind[:event],
      "command" => argv,
      "status" => "running",
      "started_unix_ms" => now,
      "finished_unix_ms" => nil,
      "exit_code" => nil,
      "stdout" => nil,
      "stderr" => nil,
      "error" => nil
    }

    state = %{state | next_log: state.next_log + 1}

    cond do
      map_size(state.in_flight) >= @max_in_flight ->
        msg = "maximum concurrent plugin commands reached (#{@max_in_flight})"
        log = %{log | "status" => "failed", "finished_unix_ms" => now, "error" => msg}
        log = %{log | "stdout" => "", "stderr" => ""}
        {:error, "plugin_command_limit_reached", msg, push(state, log)}

      (err = Paths.ensure_user_dirs(id)) != :ok ->
        {:error, "plugin_user_dir_create_failed", inspect(err), state}

      # ponytail: no default timeout (as herdr), so 32 hung commands block every plugin
      # run until one exits; pass Command's :timeout_ms if that bites
      true ->
        env = Env.for_command(p, ctx, kind)
        opts = [tmp_dir: Paths.plugin_state_dir(id)]

        task =
          Task.Supervisor.async_nolink(state.tasks, Command, :run, [
            argv,
            p["plugin_root"],
            env,
            opts
          ])

        state = %{state | in_flight: Map.put(state.in_flight, task.ref, log["log_id"])}
        {:ok, log, push(state, log)}
    end
  end

  defp finish(state, ref, r) do
    {log_id, in_flight} = Map.pop(state.in_flight, ref)
    ok = r.exit_code == 0 and r.error == nil

    done = %{
      "status" => if(ok, do: "succeeded", else: "failed"),
      "finished_unix_ms" => System.os_time(:millisecond),
      "exit_code" => r.exit_code,
      "stdout" => String.replace_invalid(r.stdout),
      "stderr" => String.replace_invalid(r.stderr),
      "error" => r.error
    }

    logs = Enum.map(state.logs, &if(&1["log_id"] == log_id, do: Map.merge(&1, done), else: &1))
    %{state | in_flight: in_flight, logs: logs}
  end

  defp push(state, log), do: %{state | logs: Enum.take([log | state.logs], @log_limit)}

  @doc false
  # the menu catalog and the event subscription, from a fresh registry read
  def run_sync(state) do
    plugins = Registry.plugins()
    Menu.refresh(plugins)

    hooked =
      for(p <- runnable(plugins), h <- p["events"], uniq: true, do: h["on"]) |> Enum.sort()

    case GenServer.whereis(Events) do
      nil -> state
      _ when hooked == [] and state.events == nil -> state
      _ when hooked == [] -> unsubscribe(state)
      _ when hooked == state.hooked and state.events != nil -> state
      pid -> subscribe(state, pid, hooked)
    end
  end

  defp unsubscribe(state) do
    Process.demonitor(state.events, [:flush])
    :ok = Events.unsubscribe(self())
    %{state | hooked: [], events: nil}
  catch
    :exit, _ -> %{state | hooked: [], events: nil}
  end

  defp subscribe(state, pid, hooked) do
    :ok = Events.subscribe(self(), Enum.map(hooked, &%{"type" => &1}))
    ref = state.events || Process.monitor(pid)
    %{state | hooked: hooked, events: ref}
  catch
    :exit, _ -> state
  end

  defp snapshot do
    Store.snapshot()
  catch
    :exit, _ -> nil
  end

  defp guarded(state, fun, args), do: guard(fun, [state | args], fn _msg -> state end)

  # the Guard boundary: a failure is logged and answered by `on_failure.(message)`
  defp guard(fun, args, on_failure) do
    case Guard.run(__MODULE__, fun, args, server: Store.reload_server(), scan: false) do
      {:ok, value} ->
        value

      {:failed, why} ->
        msg = Guard.message(why)
        Logger.warning("plugin runtime #{fun} failed: #{msg}")
        on_failure.(msg)
    end
  end

  # herdr omits absent fields
  defp public(map), do: Map.reject(map, fn {_, v} -> v == nil end)

  defp action_info(p, a) do
    %{
      "plugin_id" => p["plugin_id"],
      "action_id" => a["id"],
      "title" => a["title"],
      "description" => a["description"],
      "contexts" => if(a["contexts"] == [], do: nil, else: a["contexts"]),
      "command" => a["command"],
      "platforms" => a["platforms"] || p["platforms"]
    }
    |> public()
  end
end
