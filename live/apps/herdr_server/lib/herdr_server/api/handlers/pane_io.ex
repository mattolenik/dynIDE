defmodule HerdrServer.Api.Handlers.PaneIo do
  @moduledoc """
  Handlers for `pane.send_text`, `send_keys`, `run`, `read` and `wait_for_output`. They
  run in the connection process, so a long `wait_for_output` blocks only its own
  connection; it polls the pane text every #{100} ms.
  """

  alias HerdrServer.Api.{Ids, Keys}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.{Input, Rows}

  @chunk 65_536
  @poll_ms 100
  @recent_default 80

  @spec handle(String.t(), map()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def handle("pane.send_text", %{pane_id: id, text: text}) do
    with {:ok, %{pty: pty}} <- lookup(id), do: write_chunks(pty, text) |> ok()
  end

  def handle("pane.send_keys", %{pane_id: id, keys: keys}) do
    with {:ok, _} <- lookup(id),
         {:ok, events} <- parse_all(keys) do
      events |> Enum.find_value(&send_err(Input.key(&1, id))) |> ok()
    end
  end

  def handle("pane.run", %{pane_id: id, command: cmd}) do
    with {:ok, _} <- lookup(id) do
      case Input.paste(cmd, id) do
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

  def handle("pane.wait_for_output", %{pane_id: id} = p) do
    with {:ok, matcher} <- matcher(p), {:ok, _} <- lookup(id) do
      deadline = p[:timeout_ms] && System.monotonic_time(:millisecond) + p.timeout_ms
      wait(id, p, matcher, deadline)
    end
  end

  # --- wait ---

  defp wait(id, p, matcher, deadline) do
    with {:ok, vt} <- vt(id) do
      src = source(p)

      case vt |> text(src, p[:lines]) |> String.split("\n") |> Enum.find(matcher) do
        nil -> sleep_or_timeout(id, p, matcher, deadline)
        line -> {:ok, %{type: "output_matched", pane_id: Ids.pane(id), line: line}}
      end
    end
  end

  defp sleep_or_timeout(id, p, matcher, deadline) do
    if deadline && System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout, "no output matched within #{p.timeout_ms} ms"}
    else
      Process.sleep(@poll_ms)
      wait(id, p, matcher, deadline)
    end
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

  defp write_chunks(pty, <<c::binary-size(@chunk), rest::binary>>),
    do: send_err(Kernel.pty().write(pty, c)) || write_chunks(pty, rest)

  defp write_chunks(_pty, <<>>), do: nil
  defp write_chunks(pty, bin), do: send_err(Kernel.pty().write(pty, bin))

  # :ok stays :ok; an error becomes the {:error, code, msg} the router returns
  defp send_err(:ok), do: nil
  defp send_err({:error, :backpressure}), do: {:error, :backpressure, "pane input is backed up"}
  defp send_err({:error, {:truncated, _}}), do: {:error, :backpressure, "pane input is backed up"}
  defp send_err({:error, :closed}), do: {:error, :not_found, "pane has exited"}
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
