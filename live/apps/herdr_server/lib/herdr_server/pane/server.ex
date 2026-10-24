defmodule HerdrServer.Pane.Server do
  @moduledoc """
  One per pane. Subscribes to its pty on init (so a restart resubscribes and gets a forced
  full damage), drains `dirty_rows` on `{:damage, ...}` into the shared row cache
  (`Pane.Rows`, with the cursor read on the same damage) and tells every registered client session `{:pane_damage, id, gen}`.
  Pane exit and title events go to `App.Store` by cast (the Store calls this process, so
  calling back would be a cycle). Kernel events carry the keeper id (`state.kernel_id`,
  from `Pane.Rows.kernel_id/1`); this process translates them to its pane id. `hidden` is
  mirrored (`HerdrServer.Mirror.pane/1`) so a restarted server starts with it.

  This is the only caller of `dirty_rows/1` (one shared read cursor per vt).

  Terminal facts (`Pane.Facts`): the scrollbar is re-read on every damage (one snapshot
  read) and after a scroll or resize; the alt-screen mode on damage with dirty rows (a
  screen switch dirties at least the cursor row; not every row) and after a scroll,
  resize or init. Facts are written when `scrolled`, the scroll values while scrolled,
  or a non-scroll fact change; sessions get `{:pane_facts, id}` only when the pane becomes
  scrolled or unscrolled, or its scroll values change while scrolled. Raw titles, OSC 7
  and the `:osc` codes are parsed by `Pane.Osc`; bells and child OSC 52 go to the
  foreground client (`Client.Foreground`). Host colours (`Pane.Facts.host_colors/0`)
  are applied on init, since the vt's colours do not survive a restore or handoff.

  Writes (`write/2`) queue in `pending` and go to the pty one chunk of at most
  65_536 bytes per message, so damage and scrolls interleave with a long paste. A
  `{:error, :backpressure}` retries the same chunk after 2 ms, doubling to 20 ms; any
  other error drops the queue. `Pane.Facts`' pending count is raised by the writer
  before its cast and lowered here once a write is out (or dropped), so a writer that
  sees no pending writes knows its direct pty write keeps order (`Pane.Input`). A dropped
  paste payload tells its origin (`write/3`) how many of its bytes went out.

  Restart window: `init/1` resets the pending count (a crashed server's queue is gone).
  A write cast that a writer bumped and sent while the new server was starting can sit in
  the mailbox past that reset; it is still written, but until then the count reads 0, so
  that writer's next input may go to the pty ahead of it.
  """
  use GenServer, restart: :transient

  require Logger

  alias HerdrReload.Guard
  alias HerdrServer.App.Store
  alias HerdrServer.Client.Foreground
  alias HerdrServer.{Kernel, Mirror}
  alias HerdrServer.Pane.{Facts, Osc, Rows, State}

  # facts a restarted server reads back from `Pane.Facts`
  @kept [:cwd, :title, :stripped_title, :progress]

  def start_link(id), do: GenServer.start_link(__MODULE__, id, name: via(id))

  defp via(id), do: {:via, Registry, {HerdrServer.Pane.Registry, id}}

  @doc "Resizes vt and pty (`cell_px` is the driving client's, may be nil) and repaints."
  @spec resize(pos_integer, pos_integer, pos_integer, {pos_integer, pos_integer} | nil) ::
          :ok | nil
  def resize(id, cols, rows, cell_px), do: call(id, {:resize, cols, rows, cell_px})

  @spec set_hidden(pos_integer, boolean) :: :ok | nil
  def set_hidden(id, hidden?), do: call(id, {:hidden, hidden?})

  @doc """
  Moves the pane's viewport (every client showing it sees the move): `{:delta, n}`
  rows (n < 0 is up), `:bottom`, or `{:top, row}` (the screen row at the viewport top).
  Clamped to the scrollback.
  """
  @spec scroll(pos_integer, {:delta, integer} | :bottom | {:top, non_neg_integer}) :: :ok
  def scroll(id, req), do: GenServer.cast(via(id), {:scroll, req})

  @doc """
  Appends `iodata` to the pane's write queue (see moduledoc). The pending count goes up
  in the caller, before the cast, so the caller's next input sees it. `paste_origin`
  marks a paste payload: if the queue is dropped before it is out, that pid gets
  `{:notice, %{level: :warning, text: "paste truncated after N bytes"}}`.
  """
  @spec write(pos_integer, iodata, pid | nil) :: :ok
  def write(id, iodata, paste_origin \\ nil) do
    :ok = Facts.add_pending(id, 1)
    GenServer.cast(via(id), {:write, iodata, paste_origin})
  end

  defp call(id, msg) do
    GenServer.call(via(id), msg)
  catch
    # the pane closed under us; callers treat it as absent
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      nil

    # a pane stuck behind its vt must not take the caller (the Store) down
    :exit, {:timeout, _} ->
      Logger.warning("pane #{id}: #{inspect(msg)} timed out")
      nil
  end

  @impl true
  def init(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt, pty: pty}} <- Kernel.keeper().lookup(kid) do
      kernel_ok(id, :subscribe, Kernel.pty().subscribe(pty, self()))
      # a restart keeps the visibility the Store last set (the pty kept it too)
      hidden = match?(%{hidden: true}, Mirror.pane(id))
      state = %State{id: id, kernel_id: kid, vt: vt, pty: pty, hidden: hidden}
      # a restart keeps what the child reported (cwd, title, progress)
      state = struct(state, Map.take(Facts.get(id) || %{}, @kept))
      scroll = Kernel.vt().scrollbar(vt)

      state = %{
        state
        | colors: apply_host_colors(id, vt),
          scroll: scroll,
          alt_screen: alt_screen?(vt)
      }

      :ok = Facts.put(id, facts(state))
      # a restarted server starts with an empty queue
      :ok = Facts.reset_pending(id)
      {:ok, reload(state)}
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call({:resize, cols, rows, cell_px}, _from, state) do
    state = Map.merge(%State{}, state)
    sb = Kernel.vt().scrollbar(state.vt)
    kernel_ok(state.id, :vt_resize, Kernel.vt().resize(state.vt, cols, rows, cell_px))
    kernel_ok(state.id, :pty_resize, Kernel.pty().resize(state.pty, cols, rows, cell_px))
    # herdr keeps a scrolled-back viewport the same distance from the bottom
    keep_from_bottom(state, sb.total - sb.viewport - sb.offset)
    {:reply, :ok, state |> scroll_facts(true) |> reload()}
  end

  def handle_call({:hidden, hidden?}, _from, state) do
    state = Map.merge(%State{}, state)
    kernel_ok(state.id, :set_hidden, Kernel.pty().set_hidden(state.pty, hidden?))
    :ok = Mirror.put({:pane, state.id}, %{hidden: hidden?})
    state = %{state | hidden: hidden?}
    {:reply, :ok, if(hidden?, do: state, else: reload(state))}
  end

  @impl true
  def handle_cast({:scroll, req}, state) do
    state = Map.merge(%State{}, state)
    sb = Kernel.vt().scrollbar(state.vt)

    target = scroll_target(req, sb)

    with true <- target != sb.offset,
         :ok <- kernel(state.id, :scroll_to, fn -> Kernel.vt().scroll_to(state.vt, target) end) do
      {:noreply, state |> scroll_facts(true) |> repaint()}
    else
      _same_or_error -> {:noreply, state}
    end
  end

  def handle_cast({:write, iodata, origin}, state) do
    state = Map.merge(%State{}, state)
    bin = IO.iodata_to_binary(iodata)
    meta = if is_pid(origin), do: {origin, 0}
    if bin == "", do: written_empty(state), else: {:noreply, enqueue(state, {bin, meta})}
  end

  def handle_cast(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:damage, kid, _gen}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)
    drain(kid)

    case Kernel.vt().dirty_rows(state.vt) do
      # no row changed: publish only if the cursor moved
      {gen, []} ->
        state = scroll_facts(state)
        cursor = read_cursor(state.vt)

        {:noreply,
         if(cursor == state.cursor, do: state, else: publish(%{state | gen: gen}, cursor))}

      {gen, dirty} ->
        state = scroll_facts(state, true)
        {:noreply, publish(%{state | gen: gen, rows: Enum.reduce(dirty, state.rows, &put_row/2)})}
    end
  end

  def handle_info({:exit, kid, _status}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)
    Store.event_async({:pane_exited, state.id})
    {:noreply, state}
  end

  def handle_info({:title, kid, raw}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)

    case osc(:title, [raw], :error) do
      :error ->
        {:noreply, state}

      title ->
        Store.event_async({:pane_title, state.id, title})
        stripped = osc(:stripped_title, [title], nil)
        {:noreply, put_facts(state, %{state | title: title, stripped_title: stripped})}
    end
  end

  def handle_info({:pwd, kid, raw}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)

    case osc(:cwd, [raw], :error) do
      {:ok, path} -> {:noreply, put_cwd(state, path)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:osc, kid, code, payload}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)

    case osc(:event, [code, payload], :ignore) do
      {:cwd, path} -> {:noreply, put_cwd(state, path)}
      {:progress, p} -> {:noreply, put_facts(state, %{state | progress: p})}
      {:clipboard, text} -> {:noreply, foreground(state, {:pane_clipboard, state.id, text})}
      :ignore -> {:noreply, state}
    end
  end

  def handle_info({:bell, kid}, %{kernel_id: kid} = state) do
    state = Map.merge(%State{}, state)
    {:noreply, foreground(state, {:pane_bell, state.id})}
  end

  def handle_info(:write, state) do
    state = Map.merge(%State{}, state)
    {:noreply, write_next(%{state | write_retry: retry_timer(state.write_retry)})}
  end

  def handle_info(_other, state) do
    state = Map.merge(%State{}, state)
    {:noreply, state}
  end

  @impl true
  def code_change(_old, state, _extra), do: {:ok, Map.merge(%State{}, state)}

  # A raising kernel call (the NIFs raise ArgumentError/ErlangError) is logged and the
  # pane keeps running.
  defp kernel(id, op, fun) do
    kernel_ok(id, op, fun.())
  rescue
    e in [ArgumentError, ErlangError] -> kernel_ok(id, op, {:raised, Exception.message(e)})
  end

  # a kernel error is logged and the pane keeps running on its previous size/visibility
  defp kernel_ok(_id, _op, :ok), do: :ok

  defp kernel_ok(id, op, other) do
    Logger.warning("pane #{id}: #{op} failed: #{inspect(other)}")
    :error
  end

  # The scene's shapes are :block | :underline | :bar | :default; a hollow block
  # (unfocused) is a block. A fresh vt's style (steady block) is :default, so the host
  # keeps the user's own cursor (ruling 6: an explicit `CSI 2 q` looks the same).
  defp read_cursor(vt), do: vt |> Kernel.vt().cursor() |> cursor_style()

  defp cursor_style(%{shape: :block_hollow} = c), do: cursor_style(%{c | shape: :block})
  defp cursor_style(%{shape: :block, blinking: false} = c), do: %{c | shape: :default}
  defp cursor_style(c), do: c

  # -- facts ----------------------------------------------------------------

  defp facts(state) do
    %{
      scroll: state.scroll,
      scrolled: scrolled?(state.scroll),
      alt_screen: state.alt_screen,
      cwd: state.cwd,
      title: state.title,
      stripped_title: state.stripped_title,
      progress: state.progress
    }
  end

  defp scrolled?(%{total: t, viewport: v, offset: o}), do: o + v < t

  # one scrollbar read; `alt?` also re-reads the alt-screen mode
  defp scroll_facts(state, alt? \\ false) do
    scroll = Kernel.vt().scrollbar(state.vt)
    alt = if alt?, do: alt_screen?(state.vt), else: state.alt_screen
    put_facts(state, %{state | scroll: scroll, alt_screen: alt})
  end

  defp alt_screen?(vt) do
    case Kernel.vt().mode(vt, :alt_screen) do
      {:stale, v} -> v
      v -> v
    end
  end

  # Writes `new`'s facts when they differ from `old`'s (an unscrolled pane's scroll values
  # do not count); tells sessions when the pane scrolls.
  defp put_facts(old, new) do
    {was, now} = {facts(old), facts(new)}
    if relevant(now) != relevant(was), do: Facts.put(new.id, now)

    if now.scrolled != was.scrolled or (now.scrolled and now.scroll != was.scroll),
      do: dispatch({:pane_facts, new.id})

    new
  end

  defp relevant(%{scrolled: true} = f), do: f
  defp relevant(f), do: %{f | scroll: nil}

  defp put_cwd(%{cwd: path} = state, path), do: state

  defp put_cwd(state, path) do
    if File.dir?(path), do: put_facts(state, %{state | cwd: path}), else: state
  end

  defp foreground(state, msg) do
    :ok = Foreground.send(msg)
    state
  end

  # Pane.Osc is editable code: a bad edit gives `default` instead of crashing the pane
  defp osc(fun, args, default) do
    case Guard.run_twice(Osc, fun, args, server: Store.reload_server()) do
      {:ok, v} -> v
      {:failed, _} -> default
    end
  end

  # the colours applied (nil when none are stored or the vt refused them)
  defp apply_host_colors(id, vt) do
    hc = Facts.host_colors() || %{}
    colors = hc[:colors]

    if Map.has_key?(hc, :scheme),
      do: kernel(id, :set_color_scheme, fn -> Kernel.vt().set_color_scheme(vt, hc.scheme) end)

    if colors != nil and
         kernel(id, :set_colors, fn -> Kernel.vt().set_colors(vt, colors) end) == :ok,
       do: colors
  end

  # -- write queue ----------------------------------------------------------

  @chunk 65_536
  @retry_first_ms 2
  @retry_max_ms 20

  # `write_retry` is nil, or `{:timer, ms}` while a retry is scheduled, `{:wait, ms}` after
  # it fired and before a write succeeds (the next backoff doubles `ms`)
  defp retry_timer({:timer, ms}), do: {:wait, ms}
  defp retry_timer(other), do: other

  defp written_empty(state) do
    :ok = Facts.add_pending(state.id, -1)
    {:noreply, state}
  end

  # items are `{bin, nil | {paste_origin, bytes_written}}`
  defp enqueue(state, item) do
    if :queue.is_empty(state.pending) and state.write_retry == nil, do: send(self(), :write)
    %{state | pending: :queue.in(item, state.pending)}
  end

  defp write_next(state) do
    case :queue.out(state.pending) do
      {:empty, _} ->
        %{state | write_retry: nil}

      {{:value, {bin, meta}}, rest} ->
        n = min(byte_size(bin), @chunk)
        {chunk, left} = {binary_part(bin, 0, n), binary_part(bin, n, byte_size(bin) - n)}

        case pty_write(state, chunk) do
          :ok -> written(state, {left, sent(meta, n)}, rest)
          {:error, :backpressure} -> backoff(state)
          {:error, reason} -> drop_queue(state, reason)
        end
    end
  end

  defp sent(nil, _n), do: nil
  defp sent({origin, w}, n), do: {origin, w + n}

  defp written(state, {left, _meta} = item, rest) do
    pending =
      if left == "" do
        :ok = Facts.add_pending(state.id, -1)
        rest
      else
        :queue.in_r(item, rest)
      end

    if not :queue.is_empty(pending), do: send(self(), :write)
    %{state | pending: pending, write_retry: nil}
  end

  defp backoff(state) do
    ms =
      case state.write_retry do
        {:wait, ms} -> min(ms * 2, @retry_max_ms)
        _ -> @retry_first_ms
      end

    Process.send_after(self(), :write, ms)
    %{state | write_retry: {:timer, ms}}
  end

  defp drop_queue(state, reason) do
    n = :queue.len(state.pending)
    Logger.warning("pane #{state.id}: #{n} queued writes dropped (#{inspect(reason)})")
    :ok = Facts.add_pending(state.id, -n)

    for {_bin, {origin, w}} <- :queue.to_list(state.pending),
        do: send(origin, {:notice, %{level: :warning, text: "paste truncated after #{w} bytes"}})

    %{state | pending: :queue.new(), write_retry: nil}
  end

  # not `kernel/3`: that maps every result but `:ok` to `:error` and logs it, and this
  # caller must tell backpressure (retry, silently) from `:closed` (drop)
  defp pty_write(state, chunk) do
    Kernel.pty().write(state.pty, chunk)
  rescue
    e in [ArgumentError, ErlangError] -> {:error, {:raised, Exception.message(e)}}
  end

  # -- scrolling ------------------------------------------------------------

  defp scroll_target(req, %{total: t, viewport: v, offset: o}) do
    bottom = max(t - v, 0)

    case req do
      {:delta, n} -> o + n
      :bottom -> bottom
      {:top, row} -> row
    end
    |> max(0)
    |> min(bottom)
  end

  defp keep_from_bottom(_state, from_bottom) when from_bottom <= 0, do: :ok

  defp keep_from_bottom(state, from_bottom) do
    sb = Kernel.vt().scrollbar(state.vt)
    target = max(sb.total - sb.viewport - from_bottom, 0)

    if target != sb.offset,
      do: kernel(state.id, :scroll_to, fn -> Kernel.vt().scroll_to(state.vt, target) end),
      else: :ok
  end

  # a hidden pane scrolls but does not publish; unhiding reloads it
  defp repaint(%{hidden: true} = state), do: state
  defp repaint(state), do: reload(state)

  defp put_row({n, b}, t) when n < tuple_size(t), do: put_elem(t, n, b)
  defp put_row(_row, t), do: t

  # coalesce: one drain covers every damage already queued
  defp drain(id) do
    receive do
      {:damage, ^id, _} -> drain(id)
    after
      0 -> :ok
    end
  end

  defp reload(state) do
    {gen, rows} = Kernel.vt().full_rows(state.vt)
    publish(%{state | gen: gen, rows: rows |> Enum.map(&elem(&1, 1)) |> List.to_tuple()})
  end

  defp publish(state, cursor \\ nil) do
    cursor = cursor || read_cursor(state.vt)
    :ok = Rows.put(state.id, state.gen, state.rows, cursor)
    dispatch({:pane_damage, state.id, state.gen})
    %{state | cursor: cursor}
  end

  defp dispatch(msg) do
    Registry.dispatch(HerdrServer.Client.Registry, :clients, fn entries ->
      for {pid, _} <- entries, do: send(pid, msg)
    end)
  end
end
