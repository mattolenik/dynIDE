defmodule HerdrServer.App.Store.Carry do
  @moduledoc """
  The Store's handoff carry helpers (M5). They take and return the Store state as a plain
  map (never the struct), so an edit here recompiles this module only.

  With a broker, the latest app and the pane/keeper id map are held under `"app/store"`
  (`Handoff.Link.hold/3`) at most once per 100 ms after events that changed the app;
  `Store.flush_hold/0` (the Link's PREPARE) holds a pending one now. A new VM's
  `Store.init/1` that finds that entry adopts it (before looking at the mirror, which is
  empty in a new VM): it maps the panes the Keeper adopted in `:herdr_pane_kernel`, starts
  their `Pane.Server`s, and leaves every other keeper pane alone (they belong to whoever
  opened them, e.g. ctl). A mapped pane the Keeper lost is closed as `{:pane_exited, id}`.
  An unusable entry (its pure part runs through `HerdrReload.Guard`) is logged and
  unclaimed, and the Store starts with an empty app.
  """

  require Logger

  alias HerdrReload.Guard
  alias HerdrServer.App.Actions
  alias HerdrServer.App.Store
  alias HerdrServer.App.Upgrade
  alias HerdrServer.Handoff.Link
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Pane.Supervisor, as: Panes

  @hold_key "app/store"
  @hold_ms 100

  @doc "The broker key the app is held under."
  @spec key() :: String.t()
  def key, do: @hold_key

  # coalesced: one HOLD of the latest app per @hold_ms (the app can change per event)
  @doc "Schedules a coalesced `:hold` to self when a broker is enabled."
  @spec hold(map) :: map
  def hold(%{hold_timer: nil} = state) do
    if Link.enabled?(),
      do: %{state | hold_timer: Process.send_after(self(), :hold, @hold_ms)},
      else: state
  end

  def hold(state), do: state

  @doc "Holds the latest app with the broker now."
  @spec hold_now(map) :: map
  def hold_now(state) do
    if state.hold_timer, do: Process.cancel_timer(state.hold_timer)

    if state.app != nil do
      blob = :erlang.term_to_binary(%{v: 1, app: state.app, kernel_ids: Rows.kernel_ids()})
      Link.hold(@hold_key, blob, [])
    end

    %{state | hold_timer: nil}
  end

  @doc """
  Adopts a carried entry: `{:ok, app, sizes}` once its live panes' servers are started, or
  `:failed` (the entry is unclaimed; the keeper's panes are left alone, as unmapped ones are).
  """
  @spec adopt_carried(binary) :: {:ok, Actions.app(), map} | :failed
  def adopt_carried(blob) do
    case Guard.run_twice(__MODULE__, :adoption, [blob], server: Store.reload_server()) do
      {:ok, {app, pairs}} ->
        adopt_carried(app, pairs)

      {:failed, reason} ->
        Logger.error("handoff: unusable app/store entry: #{inspect(reason, limit: 5)}")
        Link.unclaim(@hold_key)
        :failed
    end
  end

  @doc false
  # The pure part of an adoption: the carried app (upgraded to the current structs: the
  # entry may come from an older VM) and `[{pane_id, kernel_id | nil}]` for its panes.
  # Raises on an entry of the wrong shape.
  @spec adoption(binary) :: {Actions.app(), [{pos_integer, pos_integer | nil}]}
  def adoption(blob) do
    %{v: 1, app: %{session: %{panes: %{} = panes}} = app, kernel_ids: kids} =
      :erlang.binary_to_term(blob, [:safe])

    kids = Map.new(kids)
    {Upgrade.app(app), Enum.map(Map.keys(panes), &{&1, Map.get(kids, &1)})}
  end

  @doc false
  @spec adopt_carried(Actions.app(), [{pos_integer, pos_integer | nil}]) ::
          {:ok, Actions.app(), map}
  def adopt_carried(app, pairs) do
    keeper = Kernel.keeper()
    live = Enum.filter(pairs, fn {id, kid} -> start_adopted(id, kid, keeper) end)
    # after init: drops the pane from the layout and closes whatever is left of it
    Enum.each(pairs -- live, fn {id, _} -> Store.event_async({:pane_exited, id}) end)
    unmapped = keeper.ids() -- Enum.map(live, &elem(&1, 1))
    if unmapped != [], do: Logger.info("handoff: keeper panes left alone: #{inspect(unmapped)}")
    Logger.info("handoff: adopted app with panes #{inspect(Enum.map(live, &elem(&1, 0)))}")
    # sizes are unknown here: {0, 0} makes the next settle resize each visible pane to
    # its rect (the same size it has, so no SIGWINCH)
    {:ok, app, Map.new(live, fn {id, _} -> {id, {0, 0}} end)}
  end

  @doc false
  @spec start_adopted(pos_integer, pos_integer | nil, module) :: boolean
  def start_adopted(_id, nil, _keeper), do: false

  def start_adopted(id, kid, keeper) do
    with {:ok, _} <- keeper.lookup(kid),
         :ok <- Rows.put_kernel_id(id, kid),
         {:ok, pid} when is_pid(pid) <- Panes.start_pane(id) do
      true
    else
      _ -> false
    end
  end
end
