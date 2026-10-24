defmodule HerdrTerm.Kernel.Fake.Tty do
  @moduledoc """
  In-memory `HerdrTerm.Kernel.Tty` and permanent test double. The resource is
  the pid of an Agent holding size, subscriber, written bytes, the retained
  screen and the frame log; `Fake.Blit` operates on the same resource.
  """
  @behaviour HerdrTerm.Kernel.Tty

  @init %{
    size: {80, 24, 0, 0},
    sub: nil,
    written: [],
    screen: %{},
    frames: :queue.new(),
    nframes: 0,
    frame_subs: []
  }

  @impl true
  def open, do: open([])

  @doc "Test hook: `size: {cols, rows, pw, ph}`."
  def open(opts) do
    state = Map.put(@init, :size, Keyword.get(opts, :size, @init.size))
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
  def suspend(_tty), do: :ok

  @doc "Sends `{:tty_input, binary}` to the subscriber."
  def inject(tty, bin) do
    if sub = Agent.get(tty, & &1.sub), do: send(sub, {:tty_input, bin})
    :ok
  end

  def set_size(tty, size), do: Agent.update(tty, &%{&1 | size: size})

  @spec written(pid) :: binary
  def written(tty), do: IO.iodata_to_binary(Agent.get(tty, & &1.written))
end
