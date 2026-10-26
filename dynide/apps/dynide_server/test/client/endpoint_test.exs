defmodule DynideServer.Client.EndpointTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DynideScene.Protocol
  alias DynideServer.Client.Endpoint
  alias DynideServer.Mirror

  defp info(client),
    do: %{
      kind: :term,
      transport: :ref,
      size: %{cols: 80, rows: 24},
      cell_px: nil,
      caps: %{},
      client: client
    }

  defp idle_client do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp wait_until(fun, n \\ 50) do
    cond do
      fun.() ->
        :ok

      n == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(5)
        wait_until(fun, n - 1)
    end
  end

  defp attach(client), do: GenServer.call(Protocol.endpoint(), {:attach, info(client)})

  test "a crashed session keeps the entry while its client lives, drops it when the client exits" do
    client = idle_client()
    {:ok, session, _} = attach(client)
    Mirror.put({:client, client}, %{viewports: %{}, hover: nil})

    log =
      capture_log(fn ->
        Process.exit(session, :kill)
        wait_until(fn -> :sys.get_state(Protocol.endpoint()).orphans != %{} end)
      end)

    assert log =~ ~r/herdr-event crash ts=\d+ proc=session action=none reason=:killed/
    assert Mirror.client(client) != nil

    send(client, :stop)
    wait_until(fn -> Mirror.client(client) == nil end, 20)
    assert :sys.get_state(Protocol.endpoint()).orphans == %{}
  end

  test "a client re-attaching after the crash keeps its mirrored state and is no longer orphaned" do
    client = idle_client()
    {:ok, session, _} = attach(client)
    Mirror.put({:client, client}, %{viewports: %{1 => 3}, hover: {1, 2}})

    capture_log(fn ->
      Process.exit(session, :kill)
      wait_until(fn -> :sys.get_state(Protocol.endpoint()).orphans != %{} end)
    end)

    {:ok, s2, _} = attach(client)
    assert :sys.get_state(s2).viewports == %{1 => 3}
    assert :sys.get_state(Protocol.endpoint()).orphans == %{}

    # the live session now owns the entry: the client exiting ends it normally
    ref = Process.monitor(s2)
    send(client, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}, 500
    assert Mirror.client(client) == nil
  end

  test "an endpoint restart sweeps entries of dead client pids" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, _, _}
    live = idle_client()
    Mirror.put({:client, dead}, %{})
    Mirror.put({:client, live}, %{})

    {:ok, _} = Endpoint.init(:ok)
    assert Mirror.client(dead) == nil
    assert Mirror.client(live) == %{}
    Mirror.delete({:client, live})
  end
end
