defmodule HerdrTerm.Native do
  @moduledoc """
  Rustler NIF module backed by the `herdr_term` crate.
  """
  use Rustler, otp_app: :herdr_term, crate: :herdr_term, path: "../../native/herdr_term"

  @doc "Returns the crate name; proves the NIF loads."
  @spec hello() :: String.t()
  def hello, do: :erlang.nif_error(:nif_not_loaded)
end
