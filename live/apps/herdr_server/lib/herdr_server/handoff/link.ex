defmodule HerdrServer.Handoff.Link do
  @moduledoc """
  This VM's connection to `herdr_broker` (rulings 3, 7, 9 and the wire protocol in
  `docs/herdr-live/plans/m5.md`). Without `HERDR_BROKER_SOCK` (mix test, iex) `init`
  is `:ignore` and every call below is a cheap no-op.

  With it, `init` sends HELLO and blocks application start until the broker answers
  FRESH or ADOPT* + ADOPT_END, so later children (the Keeper, `App.Store`) can claim
  adopted entries with `take_adopted/1`. HOLD/UPDATE/DROP go straight from the caller
  through the link resource in `:persistent_term`, never through this process, so
  `Keeper.open` cannot be delayed by a slow request here.

  A closed link while primary halts the VM: the broker already treats it as dead and
  adopts its panes elsewhere.
  """
  use GenServer

  require Logger

  alias HerdrServer.Handoff.{Ctl, Notice, Snapshotter}
  alias HerdrServer.Native.{Keeper, Pty}
  alias HerdrServer.Native.Link, as: NLink

  @key {__MODULE__, :link}

  defstruct link: nil, gen: 0, reason: nil, adopted: [], claimed: 0, rejected: [], released: false

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec enabled?() :: boolean
  def enabled?, do: link() != nil

  @doc "Hands `fds` (dups are sent) and `blob` to the broker under `key`."
  # fds: `Pty.pty()` or `Pty.fd()` (a plain list: the opaque pty in a union trips dialyzer)
  @spec hold(binary, binary, list) :: :ok
  def hold(key, blob, fds), do: send_frame(:hold, NLink.frame_key(key, blob), fds)

  @spec update(binary, binary) :: :ok
  def update(key, blob), do: send_frame(:update, NLink.frame_key(key, blob), [])

  @spec drop(binary) :: :ok
  def drop(key), do: send_frame(:drop, NLink.frame_key(key, ""), [])

  @doc "Claims the adopted entries whose key starts with `prefix`."
  @spec take_adopted(binary) :: [{binary, binary, [Pty.fd()]}]
  def take_adopted(prefix), do: call({:take, prefix}, [])

  @doc "Gives back a claimed entry that could not be used: `restored/0` drops it."
  @spec unclaim(binary) :: :ok
  def unclaim(key), do: call({:unclaim, key}, :ok)

  @spec adopt_reason() :: :graceful | :crash | nil
  def adopt_reason, do: call(:reason, nil)

  @doc "After an adoption: RESTORED to the broker, DROPs for unclaimed entries."
  @spec restored() :: :ok
  def restored, do: call(:restored, :ok)

  defp call(msg, disabled) do
    if GenServer.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, msg, :infinity),
      else: disabled
  end

  defp link, do: :persistent_term.get(@key, nil)

  defp send_frame(kind, body, fds) do
    with l when l != nil <- link(),
         {:error, reason} <- NLink.send(l, NLink.kind(kind), body, fds) do
      # the link is closed now; this process halts the VM on the close message
      Logger.error("handoff link: #{kind} failed: #{inspect(reason)}")
    end

    :ok
  end

  @impl true
  def init(_opts) do
    case System.get_env("HERDR_BROKER_SOCK") do
      nil -> :ignore
      path -> connect(path)
    end
  end

  defp connect(path) do
    # A restart after a crash: our old link closed with its owner, so the broker
    # has already handed our panes to another VM.
    if link(), do: halt("handoff link restarted")
    gen = "HERDR_LIVE_GEN" |> System.get_env("0") |> String.to_integer()
    os_pid = String.to_integer(System.pid())

    with {:ok, l} <- NLink.connect(path, self()),
         :ok <- NLink.send(l, NLink.kind(:hello), <<gen::64, os_pid::32>>, []) do
      {reason, adopted} = await(l, [])
      :persistent_term.put(@key, l)
      Logger.info("handoff link gen=#{gen} #{reason || :fresh} entries=#{length(adopted)}")
      {:ok, %__MODULE__{link: l, gen: gen, reason: reason, adopted: adopted}}
    else
      {:error, reason} -> {:stop, {:broker_link, reason}}
    end
  end

  @fresh NLink.kind(:fresh)
  @adopt NLink.kind(:adopt)
  @adopt_end NLink.kind(:adopt_end)

  # Plain receive on purpose: a standby VM waits here until it is promoted.
  defp await(l, acc) do
    receive do
      {:herdr_link, ^l, @fresh, _, _} ->
        {nil, []}

      {:herdr_link, ^l, @adopt, body, fds} ->
        {key, blob} = NLink.parse_key(body)
        await(l, [{key, blob, fds} | acc])

      {:herdr_link, ^l, @adopt_end, <<_count::32, r>>, _} ->
        {if(r == 0, do: :graceful, else: :crash), Enum.reverse(acc)}

      {:herdr_link_closed, ^l, reason} ->
        halt("handoff link closed before start: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_call({:take, prefix}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)

    {mine, rest} =
      Enum.split_with(state.adopted, fn {k, _, _} -> String.starts_with?(k, prefix) end)

    {:reply, mine, %{state | adopted: rest, claimed: state.claimed + length(mine)}}
  end

  def handle_call({:unclaim, key}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, :ok, %{state | rejected: [key | state.rejected], claimed: state.claimed - 1}}
  end

  def handle_call(:reason, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.reason, state}
  end

  def handle_call(:restored, _from, %{reason: nil} = state), do: {:reply, :ok, state}

  def handle_call(:restored, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    :ok = send_frame(:restored, <<state.claimed::32>>, [])
    for {k, _, _} <- state.adopted, do: drop(k)
    for k <- state.rejected, do: drop(k)
    # first UPDATEs now that the broker takes ours (it ignored them before RESTORED)
    Snapshotter.tick()
    notice(:adopted, state)
    {:reply, :ok, %{state | adopted: [], rejected: []}}
  end

  @request NLink.kind(:request)
  @prepare NLink.kind(:prepare)
  @thaw NLink.kind(:thaw)
  @release NLink.kind(:release)

  @impl true
  def handle_info({:herdr_link, _, @request, <<ref::64, payload::binary>>, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    # in a Task: a slow request never holds up PREPARE; the broker matches replies by ref
    Task.start(fn ->
      send_frame(:reply, [<<ref::64>>, :erlang.term_to_binary(request(payload))], [])
    end)

    {:noreply, state}
  end

  def handle_info({:herdr_link, _, @prepare, _, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    # notice first, so clients stop writing before the panes freeze
    notice(:begin, state)
    :ok = Keeper.prepare()
    send_frame(:prepared, "", [])
    {:noreply, state}
  end

  def handle_info({:herdr_link, _, @thaw, _, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    :ok = Keeper.thaw()
    notice(:aborted, state)
    {:noreply, state}
  end

  def handle_info({:herdr_link, _, @release, _, _}, state) do
    state = Map.merge(%__MODULE__{}, state)
    notice(:released, state)
    :ok = Keeper.release()
    Logger.info("handoff: released, stopping")
    System.stop(0)
    {:noreply, %{state | released: true}}
  end

  def handle_info({:herdr_link_closed, _, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)
    if not state.released, do: halt("handoff link closed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("handoff link: unexpected #{inspect(msg, limit: 5)}")
    {:noreply, Map.merge(%__MODULE__{}, state)}
  end

  defp request(payload) do
    Ctl.handle(:erlang.binary_to_term(payload, [:safe]))
  rescue
    ArgumentError -> {:error, :bad_request}
  end

  defp notice(phase, state),
    do: Notice.broadcast({:handoff, %{phase: phase, gen: state.gen, panes: Keeper.ids()}})

  @spec halt(binary) :: no_return
  defp halt(why) do
    Logger.error(why <> "; halting")
    :logger_std_h.filesync(:default)
    System.halt(1)
  end
end
