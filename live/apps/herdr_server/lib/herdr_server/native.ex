defmodule HerdrServer.Native do
  @moduledoc """
  Rustler NIF module backed by the `herdr_kernel` crate.
  """
  use Rustler, otp_app: :herdr_server, crate: :herdr_kernel, path: "../../native/herdr_kernel"

  @doc "Builds and drops a ghostty terminal; proves libghostty-vt is linked."
  @spec hello() :: String.t() | {:error, String.t()}
  def hello, do: :erlang.nif_error(:nif_not_loaded)
end
