defmodule HerdrTerm.Native.Desktop do
  @moduledoc """
  The client machine's clipboard, URL opener, notifier and audio player, through native
  tools spawned by the kernel (stdio null; a kernel thread writes the clipboard text to
  the tool's stdin and reaps it). macOS: `pbcopy`, `open`, `osascript` (display
  notification), `afplay`. Linux: `wl-copy` when `WAYLAND_DISPLAY` is set, then `xclip` /
  `xsel` when `DISPLAY` is set; `xdg-open`; `notify-send` when either is set; the first of
  `paplay`, `pw-play`, `ffplay`, `mpg123`, `mpv` that spawns. Elsewhere, or when no tool
  can be spawned: `{:error, :unavailable}`.
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

  @impl true
  @spec notify(binary, binary) :: :ok | {:error, :unavailable}
  def notify(title, body) when is_binary(title) and is_binary(body),
    do: Native.desktop_notify(title, body)

  @impl true
  @spec play(binary) :: :ok | {:error, :unavailable}
  def play(path) when is_binary(path), do: Native.desktop_play(path)
end
