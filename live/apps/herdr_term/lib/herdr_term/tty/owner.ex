defmodule HerdrTerm.Tty.Owner do
  @moduledoc """
  Holds the client's tty resource: opens it in `init/1`, restores it in
  `terminate/2`, subscribes the Input process to it, and turns SIGWINCH into
  a `{:resize, _}` event for Input.

  SIGWINCH: with the real tty kernel, `:os.set_signal(:sigwinch, :handle)`
  makes `erl_signal_server` emit a `:sigwinch` gen_event, and a
  `HerdrTerm.Tty.Sigwinch` handler forwards it here as `:sigwinch`. With the
  fake kernel no signal is touched; tests `send(owner, :sigwinch)`.
  """

  use GenServer

  alias HerdrTerm.{Client, Kernel}
  alias HerdrTerm.Client.Term.Input

  defstruct [:id, :tty, :size, :sigwinch]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Client.via(opts[:id], :tty_owner))

  def tty(owner), do: GenServer.call(owner, :tty)
  def subscribe(owner, pid), do: GenServer.call(owner, {:subscribe, pid})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, tty} = open(Kernel.tty(), Keyword.get(opts, :tty_opts, []))

    {:ok,
     %__MODULE__{id: opts[:id], tty: tty, size: Kernel.tty().size(tty), sigwinch: sigwinch()}}
  end

  defp open(mod, []), do: mod.open()
  defp open(mod, opts), do: mod.open(opts)

  defp sigwinch do
    if Kernel.tty() != HerdrTerm.Kernel.Fake.Tty do
      :os.set_signal(:sigwinch, :handle)
      handler = {HerdrTerm.Tty.Sigwinch, make_ref()}
      :ok = :gen_event.add_handler(:erl_signal_server, handler, self())
      handler
    end
  end

  @impl true
  def handle_call(:tty, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, state.tty, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:reply, Kernel.tty().subscribe(state.tty, pid), state}
  end

  @impl true
  def handle_info(:sigwinch, state) do
    state = Map.merge(%__MODULE__{}, state)
    size = Kernel.tty().size(state.tty)

    if size != state.size do
      {cols, rows, pw, ph} = size
      cell_px = if pw > 0 and ph > 0, do: {div(pw, cols), div(ph, rows)}

      Input.event(
        Client.via(state.id, :input),
        {:resize, %{cols: cols, rows: rows, cell_px: cell_px}}
      )
    end

    {:noreply, %{state | size: size}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = Map.merge(%__MODULE__{}, state)
    if state.sigwinch, do: :gen_event.delete_handler(:erl_signal_server, state.sigwinch, [])
    Kernel.tty().restore(state.tty)
  end
end

defmodule HerdrTerm.Tty.Sigwinch do
  @moduledoc "`erl_signal_server` handler forwarding `:sigwinch` to a `Tty.Owner`."
  @behaviour :gen_event

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_event(:sigwinch, owner) do
    send(owner, :sigwinch)
    {:ok, owner}
  end

  def handle_event(_signal, owner), do: {:ok, owner}

  @impl true
  def handle_call(_req, owner), do: {:ok, :ok, owner}
end
