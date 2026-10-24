defmodule Mix.Tasks.HerdrTerm.Demo do
  @shortdoc "Paints a fake screen to the host tty (run it via bin/live-demo)"
  @moduledoc """
  Throwaway end-to-end demo of `HerdrTerm.Native.Tty` and `HerdrTerm.Native.Blit`
  with `HerdrTerm.Demo.FakeRows`. One process, no supervisor; run it through
  `bin/live-demo`, which keeps the VM off stdio and restores the tty even
  after `kill -9`.

  Repaints every 250 ms, on input, on SIGWINCH and after resume. `q` or
  Ctrl-C quits, Ctrl-Z suspends (raw mode delivers both as bytes).
  """
  use Mix.Task

  alias HerdrTerm.Demo.FakeRows
  alias HerdrTerm.Native.{Blit, Tty}

  defmodule Winch do
    @moduledoc false
    # gen_event handler on :erl_signal_server: forwards SIGWINCH to the demo.
    @behaviour :gen_event

    @impl true
    def init(pid), do: {:ok, pid}

    @impl true
    def handle_event(:sigwinch, pid) do
      send(pid, :sigwinch)
      {:ok, pid}
    end

    def handle_event(_signal, pid), do: {:ok, pid}

    @impl true
    def handle_call(_request, pid), do: {:ok, :ok, pid}
  end

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    :ok = :os.set_signal(:sigwinch, :handle)
    :ok = :gen_event.add_sup_handler(:erl_signal_server, Winch, self())
    {:ok, tty} = Tty.open()
    :ok = Tty.subscribe(tty, self())
    {:ok, _} = :timer.send_interval(250, :tick)

    %{tty: tty, tick: 0, last_input: "", pid: System.pid()}
    |> resize()
    |> paint(true)
    |> loop()
  end

  defp loop(s) do
    receive do
      :tick -> %{s | tick: s.tick + 1} |> paint(false) |> loop()
      :sigwinch -> s |> resize() |> paint(true) |> loop()
      {:tty_resumed} -> s |> resize() |> paint(true) |> loop()
      {:tty_input, bytes} -> input(s, bytes)
      {:exit, :tty, _reason} -> System.halt(1)
    end
  end

  defp input(s, bytes) do
    cond do
      :binary.match(bytes, ["q", <<3>>]) != :nomatch ->
        Tty.restore(s.tty)

      :binary.match(bytes, <<26>>) != :nomatch ->
        # On error nothing was stopped and no {:tty_resumed} follows.
        _ = Tty.suspend(s.tty)
        loop(s)

      true ->
        %{s | last_input: bytes} |> paint(false) |> loop()
    end
  end

  defp resize(s) do
    {cols, rows, _, _} = Tty.size(s.tty)
    Map.merge(s, %{cols: max(cols, 1), rows: max(rows, 1)})
  end

  defp paint(s, repaint) do
    rows = FakeRows.frame(s.cols, s.rows, Map.take(s, [:tick, :last_input, :pid]))
    :ok = Blit.frame(s.tty, rows, %{cursor: nil, shape: :default, repaint: repaint})
    s
  end
end
