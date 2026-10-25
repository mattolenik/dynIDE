defmodule HerdrTerm.Test.FakeServer do
  @moduledoc """
  Fake server side of the client protocol: an endpoint registered under `name`
  that answers `:attach` with a fresh session process. Each session forwards
  every message it receives to the test; the test is told `{:attached, req, session}`.
  `extra` is merged into the attach reply's map (e.g. `images: mfa`).
  """

  def start(test, name, rows_mfa, extra \\ %{}) do
    pid = spawn_link(fn -> endpoint(test, Map.put(extra, :rows, rows_mfa)) end)
    Process.register(pid, name)
    pid
  end

  def unique_name, do: :"herdr_term_test_endpoint_#{System.unique_integer([:positive])}"

  defp endpoint(test, reply) do
    receive do
      {:"$gen_call", from, {:attach, req}} ->
        session = spawn(fn -> session(test) end)
        send(test, {:attached, req, session})
        GenServer.reply(from, {:ok, session, reply})
        endpoint(test, reply)
    end
  end

  defp session(test) do
    receive do
      msg ->
        send(test, msg)
        session(test)
    end
  end
end

ExUnit.start()
