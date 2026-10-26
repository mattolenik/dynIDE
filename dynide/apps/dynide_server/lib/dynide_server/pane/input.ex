defmodule DynideServer.Pane.Input do
  @moduledoc """
  Writes input to a pane: encode with the pane's vt (live modes), write to its pty.
  `key/2` is the fast-path target published by `App.Store` (contract decision 6):
  clients call `apply(Pane.Input, :key, [event, pane_id])`. Unknown panes are a no-op.
  A failed pty write is logged and dropped; `key/2` still returns `{:error, reason}` so
  a caller that can keep the input (a frozen pane is `:closed`) does.

  Pastes go through the pane's write queue (`Pane.Server.write/2`, which retries on
  backpressure). While that queue holds writes, keys, mouse and focus reports are
  encoded here and queued behind them, so they keep their order; otherwise they go to
  the pty directly. The fast path reads one ETS row (`Pane.Facts.input/1`) per key;
  modes and keyboard flags are read only for the keys that need them.

  Events are `DynideScene.Event` tuples; the kernel takes the inner map with M1's
  vocabulary (mods `:shift | :ctrl | :alt | :super`, button nil for none), so other
  modifiers are dropped here. An event the kernel rejects (`ArgumentError`) is dropped.
  """

  require Logger

  alias DynideScene.Protocol
  alias DynideServer.Kernel
  alias DynideServer.Pane.{Facts, KeyFallback, Rows, Server}

  @mods [:shift, :ctrl, :alt, :super]
  @mouse_modes [:mouse_x10, :mouse_normal, :mouse_button, :mouse_any]
  @page %{page_up: -1, page_down: 1}

  @doc """
  Encodes and writes a key. Plain page up/down scroll the host scrollback instead where
  herdr does (`host_scroll?/1`); a pane scrolled back snaps to the bottom first (not
  on releases); `KeyFallback` applies herdr's legacy key fallbacks. `host_scroll: false`
  (API keys) always sends page keys to the child.
  """
  @spec key(tuple, pos_integer, keyword) :: :ok | {:error, term}
  def key({:key, k}, id, opts \\ []) do
    with {:ok, vt, pty} <- resolve(id) do
      {scrolled?, pending?, alt?} = Facts.input(id)

      if Keyword.get(opts, :host_scroll, true) and page_key?(k) and host_scroll?(vt, alt?),
        do: page(k, id, vt),
        else: send_key(fallback(k, vt), id, vt, pty, scrolled?, pending?)
    end
  end

  defp send_key(:drop, _id, _vt, _pty, _scrolled?, _pending?), do: :ok

  defp send_key(k, id, vt, pty, scrolled?, pending?) do
    if scrolled? and k.event != :release, do: Server.scroll(id, :bottom)
    send_input(id, vt, pty, pending?, &Kernel.vt().encode_key(&1, kernel_mods(k)))
  end

  # lock modifiers are not chords (as in `KeyFallback`)
  defp page_key?(%{key: key, mods: mods}),
    do: is_map_key(@page, key) and mods -- [:caps_lock, :num_lock] == []

  defp page(%{event: :release}, _id, _vt), do: :ok

  defp page(%{key: key}, id, vt) do
    Server.scroll(id, {:delta, @page[key] * Kernel.vt().scrollbar(vt).viewport})
  end

  # herdr's `plain_page_keys_use_host_scrollback`: bracketed paste tells zsh's app cursor
  # mode apart from `less -X`. `alt?` is the facts row's (as of the last damage: a screen
  # switch redraws, so it is current by the time a page key follows)
  defp host_scroll?(vt, alt?) do
    not alt? and not Enum.any?(@mouse_modes, &mode?(vt, &1)) and
      (not mode?(vt, :cursor_keys) or mode?(vt, :bracketed_paste))
  end

  # flags are read only for the keys a fallback can change
  defp fallback(%{key: key, mods: mods} = k, vt) do
    if key in [:enter, :tab] or Enum.any?(mods, &(&1 in [:ctrl, :super, :hyper, :meta])),
      do: KeyFallback.translate(k, negotiated?(vt)),
      else: k
  end

  defp negotiated?(vt) do
    on?(Kernel.vt().kitty_keyboard_flags(vt)) != 0 or on?(Kernel.vt().modify_other_keys(vt))
  end

  @doc "Encodes and writes a mouse event; a press, release or wheel snaps a scrolled pane."
  @spec mouse(tuple, pos_integer) :: :ok | {:error, term}
  def mouse({:mouse, m}, id) do
    with {:ok, vt, pty} <- resolve(id) do
      {scrolled?, pending?, _} = Facts.input(id)
      if scrolled? and m.kind in [:press, :release, :scroll], do: Server.scroll(id, :bottom)
      m = kernel_mods(%{m | button: if(m.button == :none, do: nil, else: m.button)})
      send_input(id, vt, pty, pending?, &Kernel.vt().encode_mouse(&1, m))
    end
  end

  defp kernel_mods(ev), do: %{ev | mods: Enum.filter(ev.mods, &(&1 in @mods))}

  @doc """
  Queues a paste in the pane's write queue (`Pane.Server.write/3`), bracketed when the
  pane enabled bracketed paste (with any end marker in `bin` removed). A paste over
  `:paste_max_bytes` (default 16 MiB) is rejected. A scrolled pane snaps to the bottom.
  `origin` (a pid) is told if the queue drops the paste before it is all written.
  """
  @spec paste(binary, pos_integer, pid | nil) ::
          :ok | {:error, {:too_large, non_neg_integer, non_neg_integer} | :closed}
  def paste(bin, id, origin \\ nil) do
    max = Application.get_env(:dynide_server, :paste_max_bytes, 16_777_216)

    with {:size, n} when n <= max <- {:size, byte_size(bin)},
         {:ok, vt, _pty} <- resolve(id) do
      {scrolled?, _, _} = Facts.input(id)
      if scrolled?, do: Server.scroll(id, :bottom)
      queue_paste(id, bin, origin, mode?(vt, :bracketed_paste))
    else
      {:size, n} -> {:error, {:too_large, n, max}}
      :ok -> :ok
    end
  end

  defp queue_paste(id, bin, origin, false), do: Server.write(id, bin, origin)

  defp queue_paste(id, bin, origin, true) do
    with :ok <- Server.write(id, "\e[200~"),
         :ok <- Server.write(id, strip_end_marker(bin), origin),
         do: Server.write(id, "\e[201~")
  end

  # repeated: removing one marker can join the halves of another
  defp strip_end_marker(bin) do
    case :binary.match(bin, "\e[201~") do
      :nomatch -> bin
      _ -> bin |> :binary.replace("\e[201~", "", [:global]) |> strip_end_marker()
    end
  end

  @spec focus(boolean, pos_integer) :: :ok | {:error, term}
  def focus(focused?, id) do
    with {:ok, vt, pty} <- resolve(id) do
      {_, pending?, _} = Facts.input(id)
      send_input(id, vt, pty, pending?, &Kernel.vt().encode_focus(&1, focused?))
    end
  end

  defp resolve(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt, pty: pty}} <- Kernel.keeper().lookup(kid) do
      {:ok, vt, pty}
    else
      _ -> :ok
    end
  end

  # while the pane has queued writes, input queues behind them (order kept)
  defp send_input(id, vt, pty, pending?, encode) do
    case encode(id, encode, vt) do
      bytes when not is_binary(bytes) or bytes == "" -> :ok
      bytes when pending? -> queue_input(id, bytes)
      bytes -> write_now(id, pty, bytes)
    end
  end

  # frozen for a handoff: queued input would be acked, then dropped when the queue meets
  # the frozen pty; `:closed` makes the caller hold it (Client.Session)
  defp queue_input(id, bytes) do
    if :persistent_term.get(Protocol.handoff_key(), nil) == :begin,
      do: {:error, :closed},
      else: Server.write(id, bytes)
  end

  defp write_now(id, pty, bytes) do
    case Kernel.pty().write(pty, bytes) do
      :ok ->
        :ok

      {:error, reason} = err ->
        warn(id, reason)
        err
    end
  end

  defp encode(id, encode, vt) do
    encode.(vt)
  rescue
    e in ArgumentError ->
      warn(id, {:unencodable, Exception.message(e)})
      nil
  end

  @warn_every_ms 1000

  # at most one warning per pane per second per calling process (the caller's dictionary
  # keeps the time: writers are client processes, there is no process of our own here)
  defp warn(id, reason) do
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, :warned, id}

    if now - Process.get(key, now - @warn_every_ms) >= @warn_every_ms do
      Process.put(key, now)
      Logger.warning("pane #{id}: input dropped (#{inspect(reason)})")
    end
  end

  defp mode?(vt, mode), do: on?(Kernel.vt().mode(vt, mode))

  defp on?({:stale, b}), do: b
  defp on?(b), do: b
end
