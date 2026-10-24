defmodule HerdrTerm.Tty.OwnerTest do
  # on_local_exit and HerdrTerm.LocalClient are VM-global
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias HerdrScene.Protocol
  alias HerdrTerm.Client
  alias HerdrTerm.Kernel.Fake.Tty
  alias HerdrTerm.Test.FakeServer
  alias HerdrTerm.Tty.Owner

  def rows(_id), do: nil

  setup do
    :persistent_term.erase({HerdrTerm.Application, :local_stop})
    Application.put_env(:herdr_term, :on_local_exit, {Kernel, :send, [self(), :local_exit]})
    on_exit(fn -> Application.delete_env(:herdr_term, :on_local_exit) end)
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []})
    %{ep: ep}
  end

  # waits for a (new) local client whose children are all started
  defp await_started(except \\ nil) do
    assert_receive {:attached, _, _}, 1000

    wait_until(fn ->
      pid = Process.whereis(Protocol.local_client_name())
      pid != except and is_pid(pid) and Client.input(pid) != nil and pid
    end)
  end

  defp wait_until(fun, n \\ 100) do
    cond do
      v = fun.() -> v
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, n - 1)
    end
  end

  defp kill_render_until_down(sup, ref) do
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      0 ->
        if r = Client.render(sup), do: Process.exit(r, :kill)
        Process.sleep(10)
        kill_render_until_down(sup, ref)
    end
  end

  defp start(ep, opts \\ []) do
    sup = start_supervised!({Client, [endpoint: ep] ++ opts})
    assert_receive {:attached, _, session}
    %{sup: sup, tty: Client.tty(sup), session: session}
  end

  test "writes the host modes after open and their disables before restore", %{ep: ep} do
    %{sup: sup, tty: tty} = start(ep)
    assert Tty.written(tty) == Owner.modes_on()
    owner = Client.owner(sup)
    :erlang.trace_pattern({Tty, :_, :_}, true, [:local])
    :erlang.trace(owner, true, [:call])
    stop_supervised!(Client)
    assert_receive {:trace, ^owner, :call, {Tty, :write, [^tty, off]}}
    assert off == Owner.modes_off()
    assert_receive {:trace, ^owner, :call, {Tty, :restore, [^tty]}}
  after
    :erlang.trace_pattern({Tty, :_, :_}, false, [:local])
  end

  test "resume re-sends the modes and repaints", %{ep: ep} do
    %{sup: sup, tty: tty} = start(ep)
    :erlang.trace(Client.render(sup), true, [:receive])
    :ok = Tty.suspend(tty)
    assert_receive {:trace, _, :receive, :repaint}, 500
    assert Tty.written(tty) == Owner.modes_on() <> Owner.modes_on()
  end

  test "the local client exits when the host tty hangs up", %{ep: ep} do
    %{tty: tty} = start(ep, local: true)

    log =
      capture_log(fn ->
        Tty.hangup(tty)
        assert_receive :local_exit, 500
      end)

    assert log =~ "host terminal gone: :hangup"
  end

  test "the local client exits on {:detached, _} from the server", %{ep: ep} do
    %{sup: sup} = start(ep, local: true)
    send(Client.render(sup), {:detached, :requested})
    assert_receive :local_exit, 500
  end

  test "other clients only log a hangup or a detach", %{ep: ep} do
    %{sup: sup, tty: tty} = start(ep)
    Tty.hangup(tty)
    send(Client.render(sup), {:detached, :requested})
    refute_receive :local_exit, 100
    assert Process.alive?(Client.owner(sup))
  end

  test "SIGWINCH becomes a resize event, a 0x0 size is clamped", %{ep: ep} do
    %{sup: sup, tty: tty, session: session} = start(ep)
    Tty.set_size(tty, {100, 30, 0, 0})
    send(Client.owner(sup), :sigwinch)
    assert_receive {:input, from, seq, {:resize, %{cols: 100, rows: 30, cell_px: nil}}}
    send(from, {:ack, seq})
    Tty.set_size(tty, {0, 0, 0, 0})
    send(Client.owner(sup), :sigwinch)
    assert_receive {:input, _, _, {:resize, %{cols: 1, rows: 1}}}
    assert is_pid(session)
  end

  describe "HerdrTerm.Application.start_local/1" do
    test "local client waits for the endpoint" do
      on_exit(fn -> Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient) end)
      ep = FakeServer.unique_name()
      starter = Task.async(fn -> HerdrTerm.Application.start_when_ready(endpoint: ep) end)
      Process.sleep(100)
      # a standby VM: no endpoint, so no tty is opened
      assert Process.whereis(Protocol.local_client_name()) == nil
      FakeServer.start(self(), ep, {__MODULE__, :rows, []})
      assert {:ok, pid} = Task.await(starter)
      assert Process.whereis(Protocol.local_client_name()) == pid
      assert_receive {:attached, _, _}
    end

    test "local client stops on handoff begin", %{ep: ep} do
      on_exit(fn -> Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient) end)
      {:ok, pid} = HerdrTerm.Application.start_local(endpoint: ep)
      assert_receive {:attached, %{client: render}, _}
      owner = Client.owner(pid)
      tty = Client.tty(pid)
      :erlang.trace_pattern({Tty, :_, :_}, true, [:local])
      :erlang.trace(owner, true, [:call])
      ref = Process.monitor(pid)
      send(render, {:handoff, %{phase: :begin, gen: 1, panes: []}})
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1000
      assert_receive {:trace, ^owner, :call, {Tty, :restore, [^tty]}}
      # stopping the client does not stop herdr-live
      refute_received :local_exit
    after
      :erlang.trace_pattern({Tty, :_, :_}, false, [:local])
    end

    test "an aborted handoff starts the local client again", %{ep: ep} do
      on_exit(fn ->
        :persistent_term.erase(Protocol.handoff_key())
        Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient)
      end)

      starter = Task.async(fn -> HerdrTerm.Application.run_local(endpoint: ep) end)
      assert_receive {:attached, %{client: render}, _}
      old = Process.whereis(Protocol.local_client_name())
      ref = Process.monitor(old)
      :persistent_term.put(Protocol.handoff_key(), :begin)
      send(render, {:handoff, %{phase: :begin, gen: 1, panes: []}})
      assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 1000
      refute_receive {:attached, _, _}, 100
      :persistent_term.put(Protocol.handoff_key(), :aborted)
      assert_receive {:attached, %{client: render2}, _}, 1000
      new = Process.whereis(Protocol.local_client_name())
      assert is_pid(new) and new != old

      # a completed handoff ends the starter
      :persistent_term.put(Protocol.handoff_key(), :begin)
      send(render2, {:handoff, %{phase: :begin, gen: 2, panes: []}})
      Process.sleep(100)
      :persistent_term.put(Protocol.handoff_key(), :released)
      assert Task.await(starter) == :ok
      assert Process.whereis(Protocol.local_client_name()) == nil
    end

    test "a crashed local client is restarted, up to the limit", %{ep: ep} do
      on_exit(fn -> Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient) end)
      opts = [endpoint: ep, restart_delay_ms: 100, max_restarts: 3, restart_window_ms: 60_000]

      log =
        capture_log([level: :info], fn ->
          starter = Task.async(fn -> HerdrTerm.Application.run_local(opts) end)

          for _ <- 1..3 do
            old = await_started()
            ref = Process.monitor(old)
            Process.exit(old, :kill)
            assert_receive {:DOWN, ^ref, _, _, _}
          end

          # the fourth crash is past the limit
          Process.exit(await_started(), :kill)
          assert Task.await(starter) == :ok
        end)

      assert Process.whereis(Protocol.local_client_name()) == nil
      assert length(Regex.scan(~r/crash ts=\d+ proc=local_client action=restarted/, log)) == 3
      assert log =~ ~r/crash ts=\d+ proc=local_client action=gave_up/
    end

    test "a Render crash loop escalates and the local client is restarted", %{ep: ep} do
      on_exit(fn -> Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient) end)
      opts = [endpoint: ep, restart_delay_ms: 20]

      log =
        capture_log([level: :info], fn ->
          starter = Task.async(fn -> HerdrTerm.Application.run_local(opts) end)
          old = await_started()
          ref = Process.monitor(old)
          kill_render_until_down(old, ref)
          new = await_started(old)
          assert new != old
          assert Process.whereis(Protocol.local_client_name()) == new

          # a deliberate stop ends the starter
          Client.stop_local()
          assert Task.await(starter) == :ok
        end)

      assert log =~ ~r/crash ts=\d+ proc=local_client action=restarted/
      assert Process.whereis(Protocol.local_client_name()) == nil
    end

    test "a client that fails to start counts against the limit", %{ep: ep} do
      opts = [
        endpoint: ep,
        tty_opts: %{error: :enxio},
        restart_delay_ms: 10,
        max_restarts: 3,
        restart_window_ms: 60_000
      ]

      log =
        capture_log([level: :info], fn -> assert HerdrTerm.Application.run_local(opts) == :ok end)

      assert length(Regex.scan(~r/proc=local_client action=restarted/, log)) == 3
      assert length(Regex.scan(~r/terminal client not started/, log)) == 4
      assert log =~ ~r/proc=local_client action=gave_up/
      assert Process.whereis(Protocol.local_client_name()) == nil
    end

    test "a deliberate stop of the local client is not restarted", %{ep: ep} do
      starter =
        Task.async(fn -> HerdrTerm.Application.run_local(endpoint: ep, restart_delay_ms: 20) end)

      await_started()
      Client.stop_local()
      assert Task.await(starter) == :ok
      refute_receive {:attached, _, _}, 100
      assert Process.whereis(Protocol.local_client_name()) == nil
    end

    test "other clients ignore a handoff", %{ep: ep} do
      %{sup: sup} = start(ep)
      send(Client.render(sup), {:handoff, %{phase: :begin, gen: 1, panes: []}})
      Process.sleep(50)
      assert Process.alive?(sup)
    end

    test "an open error is logged once and leaves the app running", %{ep: ep} do
      log =
        capture_log(fn ->
          assert {:error, _} =
                   HerdrTerm.Application.start_local(endpoint: ep, tty_opts: %{error: :enxio})
        end)

      assert [_] = Regex.scan(~r/terminal client not started: \{:tty_open, :enxio\}/, log)
      refute log =~ "terminal client started"
      assert Process.whereis(Protocol.local_client_name()) == nil
      assert Process.alive?(Process.whereis(HerdrTerm.Supervisor))
    end

    test "starts the local client, temporary", %{ep: ep} do
      on_exit(fn -> Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient) end)

      assert capture_log(fn ->
               assert {:ok, pid} = HerdrTerm.Application.start_local(endpoint: ep)
               assert Process.whereis(Protocol.local_client_name()) == pid
             end) =~ "terminal client started"

      assert_receive {:attached, _, _}
      Tty.hangup(Client.tty(Protocol.local_client_name()))
      assert_receive :local_exit, 500
      Process.exit(Process.whereis(Protocol.local_client_name()), :kill)
      Process.sleep(20)
      assert Process.whereis(Protocol.local_client_name()) == nil
    end
  end
end
