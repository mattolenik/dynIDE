defmodule HerdrServer.Api.Handlers.PaneIo do
  @moduledoc """
  Handlers for `pane.send_text`, `send_keys`, `run`, `read` and `wait_for_output`. They
  run in the connection process, so a long `wait_for_output` blocks only its own
  connection; `Api.Conn` polls it every 100 ms.
  """

  alias HerdrServer.Api.{Ids, Keys}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.{Facts, Input, Rows, Server}

  @chunk 65_536
  @recent_default 80

  @spec handle(String.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()} | {:error, atom(), String.t(), map()}
  # behind a queued paste (`pane.run`) the text queues too, so it cannot overtake it
  def handle("pane.send_text", %{pane_id: id, text: text}) do
    with {:ok, %{pty: pty}} <- lookup(id) do
      if Facts.pending?(id),
        do: Server.write(id, text) |> send_err() |> ok(),
        else: write_chunks(pty, text, 0)
    end
  end

  def handle("pane.send_keys", %{pane_id: id, keys: keys}) do
    with {:ok, _} <- lookup(id),
         {:ok, events} <- parse_all(keys) do
      events |> Enum.find_value(&send_err(Input.key(&1, id, host_scroll: false))) |> ok()
    end
  end

  # The command is a paste: it goes to the pane's retrying write queue (`Pane.Input`), so
  # it answers only too_large (invalid_params) or closed (not_found). The Enter queues
  # behind a non-empty queue, but is written straight to the pty once it has drained
  # (`Input.key` -> write_now), so it can answer backpressure (also on a truncated
  # write) or failed. A later kernel failure of queued bytes is logged by the pane.
  def handle("pane.run", %{pane_id: id, command: cmd}) do
    with {:ok, _} <- lookup(id) do
      case paste(cmd, id) do
        :ok -> id |> then(&Input.key(Keys.parse("enter") |> elem(1), &1)) |> send_err() |> ok()
        err -> err |> send_err() |> ok()
      end
    end
  end

  def handle("pane.read", %{pane_id: id} = p) do
    with {:ok, vt} <- vt(id) do
      src = source(p)

      {:ok,
       %{type: "pane_read", pane_id: Ids.pane(id), source: src, text: text(vt, src, p[:lines])}}
    end
  end

  @doc """
  `pane.wait_for_output`: answers at once when a line matches, else
  `{:continue, {__MODULE__, :poll_output, [params, deadline]}}`, which `Api.Conn` runs
  every 100 ms until it answers (it ends the wait itself when the client closes). The
  continuation holds only data, never a fun, so a reload moves a running wait onto new
  code at its next poll.
  """
  @spec wait_for_output(map(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()} | {:continue, {module(), atom(), list()}}
  def wait_for_output(%{pane_id: id} = p, _ctx) do
    with {:ok, _} <- matcher(p), {:ok, _} <- lookup(id) do
      deadline = p[:timeout_ms] && System.monotonic_time(:millisecond) + p.timeout_ms
      poll_output(p, deadline, nil)
    end
  end

  @doc false
  # One poll of a running wait (see `wait_for_output/2`).
  @spec poll_output(map(), integer() | nil, map() | nil) ::
          {:ok, map()} | {:error, atom(), String.t()} | {:continue, {module(), atom(), list()}}
  def poll_output(%{pane_id: id} = p, deadline, _ctx) do
    with {:ok, matcher} <- matcher(p), {:ok, vt} <- vt(id) do
      case vt |> text(source(p), p[:lines]) |> String.split("\n") |> Enum.find(matcher) do
        nil -> not_yet(p, deadline)
        line -> {:ok, %{type: "output_matched", pane_id: Ids.pane(id), line: line}}
      end
    end
  end

  defp not_yet(p, deadline) do
    if deadline && System.monotonic_time(:millisecond) >= deadline,
      do: {:error, :timeout, "no output matched within #{p.timeout_ms} ms"},
      else: {:continue, {__MODULE__, :poll_output, [p, deadline]}}
  end

  defp matcher(%{match: m, regex: r}) when is_binary(m) and is_binary(r),
    do: {:error, :invalid_params, "give exactly one of match and regex"}

  defp matcher(%{match: m}) when is_binary(m), do: {:ok, &String.contains?(&1, m)}

  defp matcher(%{regex: r}) when is_binary(r) do
    case Regex.compile(r) do
      {:ok, re} -> {:ok, &Regex.match?(re, &1)}
      {:error, {msg, _}} -> {:error, :invalid_params, "bad regex: #{msg}"}
    end
  end

  defp matcher(_), do: {:error, :invalid_params, "give exactly one of match and regex"}

  # --- text ---

  defp source(p), do: to_string(p[:source] || "visible")

  # The last `n` lines of content. The screen's own blank rows end the scrollback, so
  # read `n` plus one viewport of rows, drop the trailing blanks, then keep the last `n`.
  defp text(vt, "recent", lines) do
    n = lines || @recent_default
    sb = Kernel.vt().scrollbar(vt)
    first = max(sb.total - n - sb.viewport, 0)

    if sb.total == 0,
      do: "",
      else: vt |> Kernel.vt().read_text({:rows, first..(sb.total - 1)}) |> clean(n)
  end

  defp text(vt, _visible, lines), do: vt |> Kernel.vt().read_text(:viewport) |> clean(lines)

  defp clean(text, lines) do
    all = text |> String.split("\n") |> Enum.map(&String.trim_trailing/1) |> drop_blank()
    all = if lines, do: Enum.take(all, -lines), else: all
    Enum.join(all, "\n")
  end

  defp drop_blank(rows),
    do: rows |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

  # --- helpers ---

  defp parse_all(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn k, {:ok, acc} ->
      case Keys.parse(k) do
        {:ok, ev} -> {:cont, {:ok, [ev | acc]}}
        {:error, msg} -> {:halt, {:error, :invalid_params, "key #{inspect(k)}: #{msg}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # A failed chunk answers its error with `data.written` (bytes already written), so a
  # client retrying after `backpressure` resends only the rest.
  defp write_chunks(_pty, <<>>, _written), do: ok(nil)

  defp write_chunks(pty, bin, written) do
    {c, rest} =
      if byte_size(bin) > @chunk, do: :erlang.split_binary(bin, @chunk), else: {bin, <<>>}

    case send_err(Kernel.pty().write(pty, c)) do
      nil -> write_chunks(pty, rest, written + byte_size(c))
      {:error, code, msg} -> {:error, code, msg, %{written: written}}
    end
  end

  # :ok stays :ok; an error becomes the {:error, code, msg} the router returns
  # an empty command pastes nothing: only the Enter is written
  defp paste("", _id), do: :ok
  defp paste(cmd, id), do: Input.paste(cmd, id)

  defp send_err(:ok), do: nil
  defp send_err({:error, :backpressure}), do: {:error, :backpressure, "pane input is backed up"}
  defp send_err({:error, {:truncated, _}}), do: {:error, :backpressure, "pane input is backed up"}
  defp send_err({:error, :closed}), do: {:error, :not_found, "pane has exited"}

  defp send_err({:error, {:too_large, n, max}}),
    do: {:error, :invalid_params, "input is #{n} bytes, over the #{max} byte paste limit"}

  defp send_err({:error, r}), do: {:error, :failed, "write failed: #{inspect(r)}"}

  defp ok(nil), do: {:ok, %{type: "ok"}}
  defp ok({:error, _, _} = e), do: e

  defp vt(id) do
    with {:ok, %{vt: vt}} <- lookup(id), do: {:ok, vt}
  end

  defp lookup(id) do
    app = Store.snapshot()

    with true <- app != nil and Map.has_key?(app.session.panes, id),
         kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: _, pty: _} = k} <- Kernel.keeper().lookup(kid) do
      {:ok, k}
    else
      _ -> {:error, :not_found, "no such pane #{Ids.pane(id)}"}
    end
  end
end
