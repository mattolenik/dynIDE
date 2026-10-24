defmodule HerdrTerm.Kernel.Fake.Desktop do
  @moduledoc """
  `HerdrTerm.Kernel.Desktop` test double. VM-global (the caller is Render, not the
  test): `listen(pid, result)` makes every call send `{:desktop, fun, arg}` to `pid`
  and return `result` (default `:ok`); `reset/0` stops that. URL checks match the real
  kernel's.
  """
  @behaviour HerdrTerm.Kernel.Desktop

  @key __MODULE__

  @doc "Test hook: report calls to `pid`, answer `result`."
  def listen(pid, result \\ :ok), do: :persistent_term.put(@key, {pid, result})

  @doc "Test hook."
  def reset do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @impl true
  def clipboard_write(text) when is_binary(text), do: call(:clipboard_write, text)

  @impl true
  def open_url("http://" <> _ = url), do: call(:open_url, url)
  def open_url("https://" <> _ = url), do: call(:open_url, url)
  def open_url(url) when is_binary(url), do: {:error, :bad_url}

  defp call(fun, arg) do
    case :persistent_term.get(@key, nil) do
      {pid, result} ->
        send(pid, {:desktop, fun, arg})
        result

      nil ->
        :ok
    end
  end
end
