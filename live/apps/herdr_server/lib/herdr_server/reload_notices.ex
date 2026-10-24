defmodule HerdrServer.ReloadNotices do
  @moduledoc """
  Bridges `HerdrReload.Notices` and `Handoff.Notice` to the attached clients.

    * Notices: every reload event becomes `{:notice, %{level, text, source: :reload}}` sent
      to each `Client.Session` (which renders it in the status line and forwards it to its
      client). Test-on-save `:passed`/`:failed`/`:error` results are notices too; `:running` is status only.
    * Runtime status: reload, test and handoff events are folded into a
      `HerdrServer.RuntimeStatus` (shared session facts, held here); each change is written
      to `Mirror.put(:runtime_status, st)` (a new session reads it in init) and sent as
      `{:runtime_status, st}` to each session. Each handoff event arms an `:expire` tick
      30 s later (also for one seeded from the mirror); `:adopted` takes its kind from `Handoff.Link.adopt_reason/0`. On subscribe
      the modules the promotion sync loaded (`HerdrReload.Server.synced/0`) are applied as
      `{:synced, mods}` when non-empty and no reload entry exists yet (once), so a promoted
      standby shows them. The newest recorded batch (`HerdrReload.Server.batches/2`) seeds the
      same way and wins over the sync: a reload finishing before the first subscribe still shows.

  Always started. Subscribes when the `HerdrReload.Notices` registry runs (reload is
  enabled), else retries every 500 ms; a registry restart is followed the same way
  (exits are trapped: the registry links its subscribers).
  Texts are one line of at most 80 characters.
  """
  use GenServer

  alias HerdrServer.Handoff.{Link, Notice}
  alias HerdrServer.{Mirror, RuntimeStatus}

  @retry_ms 500
  @max 80
  @expire_ms 30_000
  @synced_ms 5_000

  # ref: the monitor of the reload registry we are subscribed to, or nil
  defstruct ref: nil, status: RuntimeStatus.new()

  @type t :: %__MODULE__{ref: reference() | nil, status: RuntimeStatus.t()}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    # Registry.register links us to the registry: its exit must not take us down
    Process.flag(:trap_exit, true)
    :ok = Notice.subscribe()
    # outside init: subscribing may wait on the reload server (synced/0)
    {:ok, %__MODULE__{status: seeded()}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, subscribe(state)}
  end

  @impl true
  def handle_info(:subscribe, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, subscribe(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{ref: ref} = state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, subscribe(%{state | ref: nil})}
  end

  def handle_info({:herdr_reload, event} = msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    notify(event)
    {:noreply, status(state, msg)}
  end

  def handle_info({:handoff, %{phase: phase} = m}, state) do
    state = Map.merge(%__MODULE__{}, state)
    Process.send_after(self(), :expire, @expire_ms)
    m = if phase == :adopted, do: Map.put(m, :kind, Link.adopt_reason()), else: m
    {:noreply, status(state, {:handoff, m})}
  end

  def handle_info(:expire, state) do
    state = Map.merge(%__MODULE__{}, state)
    now = System.monotonic_time(:millisecond)
    {:noreply, publish(state, RuntimeStatus.expire(state.status, now))}
  end

  def handle_info(_, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  @impl true
  # before the runtime status the state was the bare registry monitor (or nil)
  def code_change(_old, ref, _extra) when is_reference(ref) or is_nil(ref),
    do: {:ok, %__MODULE__{ref: ref, status: seeded()}}

  def code_change(_old, state, _extra), do: {:ok, Map.merge(%__MODULE__{}, state)}

  # a restarted bridge starts from the mirror; a seeded handoff entry still expires
  defp seeded do
    status = Mirror.get(:runtime_status) || RuntimeStatus.new()
    if status.handoff, do: Process.send_after(self(), :expire, @expire_ms)
    status
  end

  defp notify({:tests, :running, _}), do: :ok
  defp notify({:tests, :none, _}), do: :ok

  defp notify(event) do
    {level, text} = format(event)
    n = %{level: level, text: text, source: :reload}
    sessions(&send(&1, {:notice, n}))
  end

  defp status(state, event), do: publish(state, RuntimeStatus.apply(state.status, event))

  defp publish(%{status: st} = state, st), do: state

  defp publish(state, st) do
    Mirror.put(:runtime_status, st)
    sessions(&send(&1, {:runtime_status, st}))
    %{state | status: st}
  end

  defp sessions(f),
    do:
      Registry.dispatch(HerdrServer.Client.Registry, :clients, &for({pid, _} <- &1, do: f.(pid)))

  defp subscribe(%{ref: ref} = state) when is_reference(ref), do: state

  defp subscribe(state) do
    case Process.whereis(HerdrReload.Notices) do
      nil ->
        Process.send_after(self(), :subscribe, @retry_ms)
        state

      pid ->
        :ok = HerdrReload.Notices.subscribe()
        state = %{state | ref: Process.monitor(pid)}

        # once: on a re-subscribe (registry restart, bridge restart from the mirror) a
        # newer reload entry must not go back to the old sync
        if state.status.reload == nil, do: seed_reload(state), else: state
    end
  end

  # the newest batch (a reload that finished before we subscribed) wins over the sync
  defp seed_reload(state) do
    case newest_batch() do
      # the batch does not record why it was rolled back
      %{rolled_back: true} = b ->
        status(state, {:herdr_reload, {:rolled_back, b.id, b.modules, "earlier"}})

      %{} = b ->
        status(state, {:herdr_reload, {:loaded, b.id, b.modules}})

      nil ->
        case synced() do
          [_ | _] = mods -> status(state, {:herdr_reload, {:synced, mods}})
          _ -> state
        end
    end
  end

  defp newest_batch do
    if Process.whereis(HerdrReload.Server),
      do: List.first(HerdrReload.Server.batches(HerdrReload.Server, @synced_ms)),
      else: nil
  catch
    :exit, _ -> nil
  end

  # the promotion sync's modules; the reload server may not run (reload disabled, tests)
  defp synced do
    if Process.whereis(HerdrReload.Server),
      do: HerdrReload.Server.synced(HerdrReload.Server, @synced_ms),
      else: []
  catch
    :exit, _ -> []
  end

  @doc "The notice level and text for a reload event."
  @spec format(term) :: {:error | :warning | :info, String.t()}
  def format(event) do
    {level, text} = raw(event)
    {level, text |> String.replace(~r/\s+/, " ") |> String.slice(0, @max)}
  end

  defp raw({:compile_error, [d | _]}), do: {:error, "#{where(d)}: #{d.message}"}
  defp raw({:compile_error, []}), do: {:error, "compile error"}
  defp raw({:loaded, _id, mods}), do: {:info, "reloaded #{length(mods)} modules"}

  defp raw({:rolled_back, id, mods, reason}),
    do:
      {:warning,
       "rolled back batch #{id} (#{length(mods)} modules): #{RuntimeStatus.reason(reason)}"}

  defp raw({:rejected, mod, path}),
    do: {:warning, "rejected: local fun from #{inspect(mod)} at #{inspect(path)}"}

  defp raw({:synced, mods}),
    do: {:warning, "synced #{length(mods)} modules from disk, no rollback"}

  defp raw({:purge_blocked, mod, holders}),
    do: {:warning, "purge blocked: #{inspect(mod)} still running in #{length(holders)} processes"}

  defp raw({:tests, :passed, info}), do: {:info, "tests passed (#{info[:files]} files)"}

  defp raw({:tests, :failed, info}),
    do: {:warning, "tests failed: #{info[:failures]} failures, not loaded"}

  defp raw({:tests, :error, _}), do: {:warning, "tests error, not loaded"}

  defp raw(other), do: {:warning, "reload: #{inspect(other)}"}

  defp where(%{file: file, position: pos}) when is_binary(file),
    do: "#{Path.relative_to_cwd(file)}:#{line(pos)}"

  defp where(_), do: "compile error"

  defp line({l, _col}), do: l
  defp line(l), do: l
end
