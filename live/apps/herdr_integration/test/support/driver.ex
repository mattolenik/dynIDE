defmodule HerdrIntegration.Driver do
  @moduledoc """
  Drives real `HerdrTerm.Client`s (fake tty and blit) against the running
  `herdr_server` (fake kernel). Input goes through `Fake.Tty.inject`, so it
  takes the real path: parser, fast path or protocol, server, fake pty echo,
  damage, client render, `Fake.Blit`.

  Test-only (compiled from `test/support`). Clients are started with
  `start_supervised!`, so ExUnit stops them at the end of each test.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias HerdrScene.Cell
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel.Fake.{Keeper, Pty}
  alias HerdrServer.Pane.Rows
  alias HerdrTerm.Cells
  alias HerdrTerm.Client
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme
  alias HerdrTerm.Kernel.Fake.{Blit, Tty}

  @quiet_ms 100

  @doc "Resets the server's app state (closes every pane)."
  def reset, do: Store.reset()

  @doc """
  Starts a client with a fake tty of `{cols, rows}` and waits for its first frame.
  `opts` go to the client (e.g. `transport: :inline`).
  """
  def start_client({cols, rows}, opts \\ []) do
    id = make_ref()
    opts = [id: id, tty_opts: %{size: {cols, rows, 0, 0}}] ++ opts
    client = start_supervised!({Client, opts}, id: id)
    true = wait(client, fn -> scene(client) != nil and Blit.frames(tty(client)) != [] end)
    client
  end

  def tty(client), do: Client.tty(client)

  @doc "Injects host-tty bytes into the client's input."
  def type(client, bin), do: Tty.inject(tty(client), bin)

  @doc "Feeds `bin` as program output of pane `pane_id`."
  def output(pane_id, bin) do
    {:ok, %{pty: pty}} = Keeper.lookup(Rows.kernel_id(pane_id))
    Pty.output(pty, bin)
  end

  def screen(client), do: Blit.screen(tty(client))

  @doc "Host cursor of the client's latest frame (`{x, y}` or nil)."
  def cursor(client), do: tty(client) |> Blit.frames() |> List.last() |> Map.fetch!(:cursor)

  @doc "The latest scene the client received (from its Render process state)."
  def scene(client), do: :sys.get_state(Client.render(client)).scene

  @doc "Waits until `fun.(screen)` holds, re-checking after every frame."
  def wait_screen(client, fun, timeout \\ 1000),
    do: wait(client, fn -> fun.(screen(client)) end, timeout)

  @doc "Waits until no frame arrived for #{@quiet_ms}ms (at most 2s)."
  def quiesce(client) do
    subscribe(tty(client))
    deadline = now() + 2000
    quiet(tty(client), deadline)
  end

  defp quiet(tty, deadline) do
    receive do
      {:frame, ^tty, _} -> if now() < deadline, do: quiet(tty, deadline), else: :timeout
    after
      @quiet_ms -> :ok
    end
  end

  @doc "Left click inside pane `id`'s content rect (focuses it)."
  def click(client, id) do
    %{rect: r} = Enum.find(scene(client).panes, &(&1.id == id))
    at = "#{r.x + 1};#{r.y + 1}"
    type(client, "\e[<0;#{at}M\e[<0;#{at}m")
  end

  @doc """
  Splits until the scene has `n` panes: each time focuses the largest pane and
  splits it side by side when wide (`w > 2h`), stacked otherwise.
  """
  def grow(client, n) do
    scene = scene(client)
    count = length(scene.panes)

    if count >= n do
      scene
    else
      big = Enum.max_by(scene.panes, &(&1.rect.w * &1.rect.h))
      click(client, big.id)
      type(client, "\x02" <> if(big.rect.w > 2 * big.rect.h, do: "v", else: "-"))
      true = wait(client, fn -> length(scene(client).panes) > count end, 2000)
      grow(client, n)
    end
  end

  @doc "Text of `rect` cut out of `screen` (a list of row strings)."
  def region(%{x: x, y: y, w: w, h: h}, screen),
    do: screen |> Enum.slice(y, h) |> Enum.map(&String.slice(&1, x, w))

  @doc "The client's final scene composed with the server's current rows, as text."
  def expected_screen(client) do
    scene = scene(client)

    rows =
      Map.new(scene.panes, fn %{id: id} ->
        {_gen, tuple, _cursor} = Rows.fetch(id)
        {id, tuple}
      end)

    for {_y, row} <- Compose.frame(scene, rows, Theme.default()), do: Cells.to_text(row)
  end

  @doc """
  Records every `Fake.Blit.frame/3` call of the client's Render process (call
  tracing; `Fake.Blit` keeps only row indices) and checks each frame is a full
  grid of the scene size with every row exactly `cols` cells wide. Also counts
  the Render's row fetches (`Pane.Rows.fetch/1` calls, the rows MFA) per pane.
  """
  def trace_frames(client) do
    render = Client.render(client)
    {cols, rows, _, _} = Tty.size(tty(client))
    tracer = spawn_link(fn -> tracer(fresh(), cols, rows) end)
    :erlang.trace_pattern({Blit, :frame, 3}, true, [:local])
    :erlang.trace_pattern({Rows, :fetch, 1}, true, [:local])
    :erlang.trace(render, true, [:call, {:tracer, tracer}])
    tracer
  end

  @doc "`%{count: frames, bad: [{frame_no, why}], fetches: [pane_id]}` from a `trace_frames/1` tracer."
  def frame_stats(tracer) do
    send(tracer, {:stats, self()})

    receive do
      {:stats, ^tracer, stats} -> stats
    after
      2000 -> :timeout
    end
  end

  @doc "Zeroes a `trace_frames/1` tracer's count and violations (e.g. at the start of a phase)."
  def reset_frames(tracer) do
    send(tracer, {:reset, self()})

    receive do
      {:reset, ^tracer} -> :ok
    after
      2000 -> :timeout
    end
  end

  defp fresh, do: %{count: 0, bad: [], fetches: []}

  defp tracer(acc, cols, rows) do
    receive do
      {:reset, from} ->
        send(from, {:reset, self()})
        tracer(fresh(), cols, rows)

      {:trace, _pid, :call, {Rows, :fetch, [id]}} ->
        tracer(%{acc | fetches: acc.fetches ++ [id]}, cols, rows)

      {:trace, _pid, :call, {Blit, :frame, [_tty, frame, _opts]}} ->
        n = acc.count + 1
        widths = Enum.reject(frame, fn {_, row} -> Cell.cols(row) == cols end)

        bad =
          cond do
            length(frame) != rows -> [{n, {:rows, length(frame)}} | acc.bad]
            widths != [] -> [{n, {:widths, Enum.map(widths, &elem(&1, 0))}} | acc.bad]
            true -> acc.bad
          end

        tracer(%{acc | count: n, bad: bad}, cols, rows)

      {:stats, from} ->
        send(from, {:stats, self(), acc})
        tracer(acc, cols, rows)
    end
  end

  # Re-checks `check` after each frame of the client until true or `timeout`.
  defp wait(client, check, timeout \\ 1000) do
    tty = tty(client)
    subscribe(tty)
    deadline = now() + timeout
    poll(tty, check, deadline)
  end

  defp poll(tty, check, deadline) do
    cond do
      check.() ->
        true

      now() >= deadline ->
        false

      true ->
        receive do
          {:frame, ^tty, _} -> :ok
        after
          min(50, max(deadline - now(), 0)) -> :ok
        end

        drain(tty)
        poll(tty, check, deadline)
    end
  end

  defp drain(tty) do
    receive do
      {:frame, ^tty, _} -> drain(tty)
    after
      0 -> :ok
    end
  end

  # one frame subscription per tty per test process
  defp subscribe(tty) do
    key = {__MODULE__, :subscribed, tty}

    unless Process.get(key) do
      Blit.subscribe_frames(tty, self())
      Process.put(key, true)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
