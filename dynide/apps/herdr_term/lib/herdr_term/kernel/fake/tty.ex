defmodule HerdrTerm.Kernel.Fake.Tty do
  @moduledoc """
  In-memory `HerdrTerm.Kernel.Tty` and permanent test double. The resource is
  the pid of an Agent holding size, subscriber, written bytes, the retained
  screen and the frame log; `Fake.Blit` operates on the same resource.

  `open/1` takes the real options (`path` and `kitty_flags` are ignored) plus
  test hooks: `size: {cols, rows, pw, ph}`, `kitty: flags | nil` (what
  `kitty_keyboard/1` reports, default nil) and `error: reason` (open returns
  `{:error, reason}`). Like the real kernel, `suspend/1` returns `:ok` and the
  subscriber then gets `{:tty_resumed}`; `hangup/2` sends `{:exit, :tty, reason}`.
  """
  @behaviour HerdrTerm.Kernel.Tty

  @init %{
    size: {80, 24, 0, 0},
    kitty: nil,
    sub: nil,
    written: [],
    screen: %{},
    frames: :queue.new(),
    nframes: 0,
    frames_written: 0,
    frame_subs: []
  }

  @impl true
  def open(opts \\ %{})

  def open(%{error: reason}), do: {:error, reason}

  def open(opts) when is_map(opts) do
    state = Map.merge(@init, Map.take(opts, [:size, :kitty]))
    Agent.start_link(fn -> state end)
  end

  @impl true
  def restore(_tty), do: :ok

  @impl true
  def size(tty), do: Agent.get(tty, & &1.size)

  @impl true
  def subscribe(tty, pid), do: Agent.update(tty, &%{&1 | sub: pid})

  @impl true
  def write(tty, data), do: Agent.update(tty, &%{&1 | written: [&1.written | data]})

  @impl true
  def stats(tty),
    do: %{
      frames_written: Agent.get(tty, & &1.frames_written),
      frames_dropped: 0,
      queued_bytes: 0,
      graphics_bytes: 0,
      file_transport: :unknown
    }

  @impl true
  def kitty_keyboard(tty), do: Agent.get(tty, & &1.kitty)

  @impl true
  def suspend(tty), do: notify(tty, {:tty_resumed})

  @doc "Sends `{:tty_input, binary}` to the subscriber."
  def inject(tty, bin), do: notify(tty, {:tty_input, bin})

  @doc "Sends `{:exit, :tty, reason}` to the subscriber, as the real reader does on EOF/EIO."
  def hangup(tty, reason \\ :hangup), do: notify(tty, {:exit, :tty, reason})

  defp notify(tty, msg) do
    if sub = Agent.get(tty, & &1.sub), do: send(sub, msg)
    :ok
  end

  def set_size(tty, size), do: Agent.update(tty, &%{&1 | size: size})

  @spec written(pid) :: binary
  def written(tty), do: IO.iodata_to_binary(Agent.get(tty, & &1.written))
end
