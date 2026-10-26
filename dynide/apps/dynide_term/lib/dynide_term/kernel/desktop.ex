defmodule DynideTerm.Kernel.Desktop do
  @moduledoc """
  Desktop integration on the client machine: `DynideTerm.Native.Desktop`'s API. Every
  call returns once the tool is spawned (`:ok`) or `{:error, :unavailable}` when no
  tool exists; `open_url/1` answers `{:error, :bad_url}` for anything but `http://`
  and `https://`.
  """

  @callback clipboard_write(binary) :: :ok | {:error, atom}
  @callback open_url(binary) :: :ok | {:error, atom}
  @callback notify(title :: binary, body :: binary) :: :ok | {:error, atom}
  @callback play(path :: binary) :: :ok | {:error, atom}
end
