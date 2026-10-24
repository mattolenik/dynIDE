defmodule HerdrServer.Pane.Input do
  @moduledoc """
  Writes input to a pane: encode with the pane's vt (live modes), write to its pty.
  `key/2` is the fast-path target published by `App.Store` (contract decision 6):
  clients call `apply(Pane.Input, :key, [event, pane_id])`. Unknown panes are a no-op.

  Events are `HerdrScene.Event` tuples; the kernel takes the inner map with M1's
  vocabulary (mods `:shift | :ctrl | :alt | :super`, button nil for none), so other
  modifiers are dropped here. An event the kernel rejects (`ArgumentError`) is dropped.
  """

  require Logger

  alias HerdrServer.Kernel
  alias HerdrServer.Pane.Rows

  @mods [:shift, :ctrl, :alt, :super]

  @spec key(tuple, pos_integer) :: :ok
  def key({:key, k}, id), do: write(id, &Kernel.vt().encode_key(&1, kernel_mods(k)))

  @spec mouse(tuple, pos_integer) :: :ok
  def mouse({:mouse, m}, id) do
    m = kernel_mods(%{m | button: if(m.button == :none, do: nil, else: m.button)})
    write(id, &Kernel.vt().encode_mouse(&1, m))
  end

  defp kernel_mods(ev), do: %{ev | mods: Enum.filter(ev.mods, &(&1 in @mods))}

  @chunk 65_536

  @doc """
  Writes `bin` in chunks of at most #{@chunk} bytes, bracketed when the pane enabled
  bracketed paste, without blocking. On the first write error it stops and returns
  `{:error, {:truncated, n}}` (`n` = paste bytes written); a bracketed paste then gets
  one attempt to write the end marker alone so the pane leaves paste mode.
  """
  @spec paste(binary, pos_integer) :: :ok | {:error, {:truncated, non_neg_integer}}
  def paste(bin, id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt, pty: pty}} <- Kernel.keeper().lookup(kid) do
      bracketed? = on?(Kernel.vt().mode(vt, :bracketed_paste))
      chunks = chunks(bin)
      chunks = if bracketed?, do: [{"\e[200~", 0}] ++ chunks ++ [{"\e[201~", 0}], else: chunks
      paste_chunks(id, pty, chunks, bracketed?, 0)
    else
      _ -> :ok
    end
  end

  defp chunks(<<c::binary-size(@chunk), rest::binary>>), do: [{c, @chunk} | chunks(rest)]
  defp chunks(<<>>), do: []
  defp chunks(c), do: [{c, byte_size(c)}]

  defp paste_chunks(_id, _pty, [], _bracketed?, _n), do: :ok

  defp paste_chunks(id, pty, [{bytes, len} | rest], bracketed?, n) do
    case Kernel.pty().write(pty, bytes) do
      :ok ->
        paste_chunks(id, pty, rest, bracketed?, n + len)

      {:error, reason} ->
        warn(id, reason)
        # the start marker went out but the end marker did not: one attempt to close paste mode
        if bracketed? and bytes != "\e[200~", do: Kernel.pty().write(pty, "\e[201~")
        {:error, {:truncated, n}}
    end
  end

  @spec focus(boolean, pos_integer) :: :ok
  def focus(focused?, id), do: write(id, &Kernel.vt().encode_focus(&1, focused?))

  defp write(id, encode) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt, pty: pty}} <- Kernel.keeper().lookup(kid),
         bytes when is_binary(bytes) and bytes != "" <- encode(id, encode, vt),
         # ponytail: {:error, :backpressure} drops the input; queue in Pane.Server if it shows up
         {:error, reason} <- Kernel.pty().write(pty, bytes) do
      warn(id, reason)
    end

    :ok
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

  defp on?({:stale, b}), do: b
  defp on?(b), do: b
end
