defmodule HerdrTerm.Tty.OwnerTest do
  # on_local_exit and HerdrTerm.LocalClient are VM-global
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias HerdrTerm.Client
  alias HerdrTerm.Kernel.Fake.Tty
  alias HerdrTerm.Test.FakeServer
  alias HerdrTerm.Tty.Owner

  def rows(_id), do: nil

  setup do
    Application.put_env(:herdr_term, :on_local_exit, {Kernel, :send, [self(), :local_exit]})
    on_exit(fn -> Application.delete_env(:herdr_term, :on_local_exit) end)
    ep = FakeServer.unique_name()
    FakeServer.start(self(), ep, {__MODULE__, :rows, []})
    %{ep: ep}
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
      assert Process.whereis(HerdrTerm.LocalClient) == nil
      FakeServer.start(self(), ep, {__MODULE__, :rows, []})
      assert {:ok, pid} = Task.await(starter)
      assert Process.whereis(HerdrTerm.LocalClient) == pid
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
      assert Process.whereis(HerdrTerm.LocalClient) == nil
      assert Process.alive?(Process.whereis(HerdrTerm.Supervisor))
    end

    test "starts the local client, temporary", %{ep: ep} do
      on_exit(fn -> Supervisor.terminate_child(HerdrTerm.Supervisor, HerdrTerm.LocalClient) end)

      assert capture_log(fn ->
               assert {:ok, pid} = HerdrTerm.Application.start_local(endpoint: ep)
               assert Process.whereis(HerdrTerm.LocalClient) == pid
             end) =~ "terminal client started"

      assert_receive {:attached, _, _}
      Tty.hangup(Client.tty(HerdrTerm.LocalClient))
      assert_receive :local_exit, 500
      Process.exit(Process.whereis(HerdrTerm.LocalClient), :kill)
      Process.sleep(20)
      assert Process.whereis(HerdrTerm.LocalClient) == nil
    end
  end
end
