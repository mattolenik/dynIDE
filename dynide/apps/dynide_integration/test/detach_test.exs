defmodule DynideIntegration.DetachTest do
  @moduledoc """
  Prefix `q` end to end: the server sends `{:detached, :requested}` to the
  client that pressed it, which (as the local client) runs the local-exit hook
  (`System.stop(0)` outside tests). Another client stays attached.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideIntegration.Driver

  setup do
    Driver.reset()
    Application.put_env(:dynide_term, :on_local_exit, {Kernel, :send, [self(), :local_exit]})
    on_exit(fn -> Application.delete_env(:dynide_term, :on_local_exit) end)
  end

  test "prefix q quits the local client only" do
    local = Driver.start_client({80, 24}, local: true)
    other = Driver.start_client({80, 24})
    session = :sys.get_state(DynideTerm.Client.render(other)).session
    Driver.type(local, "\x02q")
    assert_receive :local_exit, 1000
    refute_receive :local_exit, 100
    assert Process.alive?(session)
  end
end
