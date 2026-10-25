defmodule HerdrTerm.Tty.Owner do
  @moduledoc """
  Holds the client's tty resource and the host terminal modes. Opens the tty in
  `init/1` (`%{path: "/dev/tty", kitty_flags: 1}` merged with the client's
  `tty_opts`; the kernel pushes the kitty flags, disambiguate, only when its
  probe found support) and writes the mode enables: SGR mouse with all motion
  (1000, 1002, 1003, 1006), bracketed paste (2004), focus events (1004) and colour
  scheme reports (2031). The kernel's open already
  entered the alternate screen and sent the kitty/DA1 probe. `terminate/2`
  writes the matching disables, then restores (which leaves the alt screen and
  pops the kitty flags).

  An open error stops the client before it starts (`{:shutdown, {:tty_open,
  reason}}`); `HerdrTerm.Application` logs it once and runs on headless.

  Input subscribes to the tty and forwards the rare events here:
  `{:tty_resumed}` re-sends the modes (the kernel's suspend turned them off)
  and asks Render for a full repaint; `{:exit, :tty, reason}` (host terminal
  gone) and `{:detached, reason}` (from Render, sent by the server) end the
  local client through `HerdrTerm.Client.local_exit/1`; `{:handoff, %{phase: :begin}}`
  stops the local client without stopping herdr-live (`HerdrTerm.Client.stop_local/0`).
  A remote client (`remote: true`, `HerdrTerm.Remote`, its own VM) also ends on a hangup
  or a detach, and ignores a handoff (its conn holds input across it). Other clients
  only log.

  SIGWINCH: when `HerdrTerm.Kernel.sigwinch?/0` (real tty),
  `:os.set_signal(:sigwinch, :handle)` makes `erl_signal_server` emit a
  `:sigwinch` gen_event, and a `HerdrTerm.Tty.Sigwinch` handler (a supervised
  handler, removed when this process dies) forwards it here as `:sigwinch`,
  which becomes a `{:resize, _}` event for Input. With the fake kernel no
  signal is touched; tests `send(owner, :sigwinch)`.
  """

  use GenServer

  require Logger

  alias HerdrTerm.{Client, Kernel}
  alias HerdrTerm.Client.Term.Input

  @modes_on "\e[?1000h\e[?1002h\e[?1003h\e[?1006h\e[?2004h\e[?1004h\e[?2031h"
  @modes_off "\e[?2031l\e[?1004l\e[?2004l\e[?1006l\e[?1003l\e[?1002l\e[?1000l"
  @kitty_flags 1

  defstruct [:id, :tty, :size, :sigwinch, local: false, remote: false]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Client.via(opts[:id], :tty_owner))

  def tty(owner), do: GenServer.call(owner, :tty)
  def subscribe(owner, pid), do: GenServer.call(owner, {:subscribe, pid})

  @doc "The mode enables written after open and after resume."
  def modes_on, do: @modes_on

  @doc "The mode disables written before restore."
  def modes_off, do: @modes_off

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    open_opts = Map.merge(%{path: "/dev/tty", kitty_flags: @kitty_flags}, opts[:tty_opts] || %{})

    case Kernel.tty().open(open_opts) do
      {:ok, tty} ->
        _ = Kernel.tty().write(tty, @modes_on)

        {:ok,
         %__MODULE__{
           id: opts[:id],
           tty: tty,
           size: Kernel.tty().size(tty),
           sigwinch: sigwinch(),
           local: Keyword.get(opts, :local, false),
           remote: Keyword.get(opts, :remote, false)
         }}

      {:error, reason} ->
        {:stop, {:shutdown, {:tty_open, reason}}}
    end
  end

  defp sigwinch do
    if Kernel.sigwinch?() do
      # stays set after this client stops; harmless, SIGWINCH's default action is ignore
      :ok = :os.set_signal(:sigwinch, :handle)
      handler = {HerdrTerm.Tty.Sigwinch, make_ref()}
      :ok = :gen_event.add_sup_handler(:erl_signal_server, handler, self())
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
      {cols, rows} = {max(cols, 1), max(rows, 1)}
      cell_px = if pw > 0 and ph > 0, do: {div(pw, cols), div(ph, rows)}

      Input.event(
        Client.via(state.id, :input),
        {:resize, %{cols: cols, rows: rows, cell_px: cell_px}}
      )
    end

    {:noreply, %{state | size: size}}
  end

  def handle_info({:tty_resumed}, state) do
    state = Map.merge(%__MODULE__{}, state)
    _ = Kernel.tty().write(state.tty, @modes_on)
    if pid = Client.whereis(state.id, :render), do: send(pid, :repaint)
    {:noreply, state}
  end

  def handle_info({:exit, :tty, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.warning("host terminal gone: #{inspect(reason)}")
    if state.local or state.remote, do: Client.local_exit({:tty, reason})
    {:noreply, state}
  end

  def handle_info({:detached, reason}, state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.info("detached: #{inspect(reason)}")
    if state.local or state.remote, do: Client.local_exit({:detached, reason})
    {:noreply, state}
  end

  def handle_info({:handoff, %{phase: :begin}}, %{local: true} = state) do
    state = Map.merge(%__MODULE__{}, state)
    Logger.info("handoff: releasing the host terminal")
    Client.stop_local()
    {:noreply, state}
  end

  # linked exits (trap_exit) and {:gen_event_EXIT, handler, reason}
  def handle_info(_msg, state) do
    state = Map.merge(%__MODULE__{}, state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = Map.merge(%__MODULE__{}, state)
    if state.sigwinch, do: :gen_event.delete_handler(:erl_signal_server, state.sigwinch, [])
    _ = Kernel.tty().write(state.tty, @modes_off <> "\e]0;\a")
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
