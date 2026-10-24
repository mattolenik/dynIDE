# Driven by tty_harness.py inside a pty; prints nothing. Writes `key=value`
# lines to $TTY_RESULT; $TTY_PATH names the pty (this process's /dev/tty):
#   destructor  restored | still-raw   (owner killed with :kill, no restore/1)
#   bad_frame   inspect of Blit.frame/3 on an invalid packed row
#   suspend_restored  inspect of Tty.suspend/1 after restore/1
#   suspend     ok | inspect of the failure (the harness drives SIGSTOP/SIGCONT)
alias HerdrTerm.Native.{Blit, Tty}

defmodule TtyDestructor do
  # Port programs run in their own session (no /dev/tty), so stty gets the path.
  # PENDIN is BSD tty bookkeeping XNU may leave set when ICANON is re-enabled,
  # not configuration, so it is masked (the harness does the same).
  def stty do
    {out, 0} = System.cmd("sh", ["-c", ~s(stty -a <"$TTY_PATH")])
    String.replace(out, ~r/(?<![\w-])-?pendin(?!\w)/, "")
  end

  def wait_for(want, tries \\ 20) do
    cond do
      stty() == want -> true
      tries == 0 -> false
      true -> Process.sleep(50) && wait_for(want, tries - 1)
    end
  end

  def frame(tty), do: Blit.frame(tty, [{0, HerdrScene.Cell.blank_row(4)}], opts())
  def opts, do: %{cursor: nil, shape: :default, repaint: false}

  def written(tty, n, tries \\ 100) do
    cond do
      Tty.stats(tty).frames_written >= n -> :ok
      tries == 0 -> {:not_written, n}
      true -> Process.sleep(20) && written(tty, n, tries - 1)
    end
  end

  def wait_input(want) do
    receive do
      {:tty_input, bytes} -> if bytes =~ want, do: :ok, else: wait_input(want)
    after
      30_000 -> {:no_input, want}
    end
  end

  def suspend do
    {:ok, t} = Tty.open(%{kitty_flags: 1})
    :ok = Tty.subscribe(t, self())

    with :ok <- frame(t),
         :ok <- written(t, 1),
         :ok <- Tty.suspend(t),
         :ok <- receive(do: ({:tty_resumed} -> :ok), after: (1_000 -> :no_resumed)),
         :ok <- frame(t),
         :ok <- written(t, 2),
         :ok <- wait_input("q") do
      Tty.restore(t)
    end
  end
end

before = TtyDestructor.stty()
parent = self()

owner =
  spawn(fn ->
    {:ok, _t} = Tty.open()
    send(parent, :opened)
    Process.sleep(:infinity)
  end)

destructor =
  receive do
    :opened ->
      raw? = TtyDestructor.stty() != before
      Process.exit(owner, :kill)
      :erlang.garbage_collect()
      if raw? and TtyDestructor.wait_for(before), do: "restored", else: "still-raw"
  after
    5_000 -> "open-timeout"
  end

{:ok, t2} = Tty.open()
bad_frame = Blit.frame(t2, [{0, <<1, 2, 3>>}], TtyDestructor.opts())
Tty.restore(t2)
suspend_restored = Tty.suspend(t2)

suspend = TtyDestructor.suspend()

File.write!(System.fetch_env!("TTY_RESULT"), """
destructor=#{destructor}
bad_frame=#{inspect(bad_frame)}
suspend_restored=#{inspect(suspend_restored)}
suspend=#{if suspend == :ok, do: "ok", else: inspect(suspend)}
""")
