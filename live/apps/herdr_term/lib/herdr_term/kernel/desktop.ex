defmodule HerdrTerm.Kernel.Desktop do
  @moduledoc """
  Desktop integration on the client machine: `HerdrTerm.Native.Desktop`'s API. Both
  calls return once the tool is spawned (`:ok`) or `{:error, :unavailable}` when no
  tool exists; `open_url/1` answers `{:error, :bad_url}` for anything but `http://`
  and `https://`.
  """

  @callback clipboard_write(binary) :: :ok | {:error, atom}
  @callback open_url(binary) :: :ok | {:error, atom}
end
