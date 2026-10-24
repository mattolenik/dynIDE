defmodule HerdrTerm.Native.Desktop do
  @moduledoc """
  The client machine's clipboard and URL opener, through native tools spawned by the
  kernel (stdio null; a kernel thread writes the clipboard text to the tool's stdin
  and reaps it). macOS: `pbcopy`, `open`. Linux: `wl-copy` when `WAYLAND_DISPLAY` is
  set, then `xclip` / `xsel` when `DISPLAY` is set; `xdg-open`. Elsewhere, or when no
  tool can be spawned: `{:error, :unavailable}`.
  """

  @behaviour HerdrTerm.Kernel.Desktop

  alias HerdrTerm.Native

  @impl true
  @spec clipboard_write(binary) :: :ok | {:error, :unavailable}
  def clipboard_write(text) when is_binary(text), do: Native.desktop_clipboard_write(text)

  @doc "Opens an `http://` or `https://` URL; anything else is `{:error, :bad_url}`."
  @impl true
  @spec open_url(binary) :: :ok | {:error, :unavailable | :bad_url}
  def open_url(url) when is_binary(url), do: Native.desktop_open_url(url)
end
