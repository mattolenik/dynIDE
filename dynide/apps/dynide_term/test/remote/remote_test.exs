defmodule DynideTerm.RemoteTest do
  # starts the named Conn and remote client under DynideTerm.Supervisor
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.Scene.Node
  alias DynideScene.Wire
  alias DynideTerm.{Client, Remote}
  alias DynideTerm.Kernel.Fake.Blit
  alias DynideTerm.Remote.Notice

  test "start wires the conn and a remote inline client: the server's scene is drawn" do
    dir = Path.join(System.tmp_dir!(), "hlr#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    sock = Path.join(dir, "c.sock")
    File.write!(Path.join(dir, "c.token"), "t")
    {:ok, l} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, sock}])

    on_exit(fn ->
      for id <- [DynideTerm.RemoteClient, Remote.Conn] do
        Supervisor.terminate_child(DynideTerm.Supervisor, id)
        Supervisor.delete_child(DynideTerm.Supervisor, id)
      end

      File.rm_rf(dir)
    end)

    {:ok, sup} =
      Remote.start(transport: {:unix, sock, Path.join(dir, "c.token")}, target: :session)

    {:ok, s} = :gen_tcp.accept(l, 3_000)
    {:ok, bin} = :gen_tcp.recv(s, 0, 3_000)
    assert {:ok, [{:auth, "t"} | _], _} = Wire.decode(bin, Wire.max_client_frame())

    tty = Client.tty(sup)
    Blit.subscribe_frames(tty, self())
    scene = Notice.blank(%{cols: 80, rows: 24})

    status = %{
      Node.find(scene.chrome, [:status])
      | children: [%Node{role: :text, id: :m, text: "hello"}]
    }

    scene = %{scene | chrome: %{scene.chrome | children: [status]}}
    :ok = :gen_tcp.send(s, Wire.encode({:attached, %{resumed: false, session: "default"}}))
    :ok = :gen_tcp.send(s, Wire.encode({:scene, scene}))
    assert_receive {:frame, _, _}, 3_000
    assert List.last(Blit.screen(tty)) =~ "hello"
  end

  test "preload loads every module of the client apps" do
    assert :ok = Remote.preload()
    assert :code.is_loaded(DynideTerm.Remote.Notice) != false
    assert :code.is_loaded(DynideScene.Wire) != false
  end
end
