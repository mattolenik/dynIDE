defmodule DynideTerm.Remote.ConnTest do
  # on_local_exit is VM-global; the ssh test sets OS env
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideScene.{Event, Wire}
  alias DynideScene.Scene.{Node, Pane}
  alias DynideTerm.Remote.{Conn, Notice}

  @wait 3_000
  @size %{cols: 80, rows: 24}

  setup do
    dir = Path.join(System.tmp_dir!(), "hlc#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    sock = Path.join(dir, "c.sock")
    token = Path.join(dir, "c.token")
    File.write!(token, "tok123\n")

    {:ok, l} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, sock}])

    Application.put_env(:dynide_term, :on_local_exit, {Kernel, :send, [self(), :local_exit]})

    on_exit(fn ->
      Application.delete_env(:dynide_term, :on_local_exit)
      File.rm_rf(dir)
    end)

    %{l: l, dir: dir, transport: {:unix, sock, token}}
  end

  defp start(ctx, opts \\ []) do
    name = :"conn_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge([name: name, transport: ctx.transport, session: nil, target: :session], opts)

    conn = start_supervised!({Conn, opts})
    req = %{kind: :term, transport: :inline, size: @size, cell_px: nil, caps: %{}, client: self()}
    assert {:ok, ^conn, %{rows: {Conn, :no_rows, []}}} = GenServer.call(conn, {:attach, req})
    conn
  end

  # accepts, checks auth and attach, answers attached; returns {socket, attach map}
  defp handshake(l, resumed \\ false) do
    {:ok, s} = :gen_tcp.accept(l, @wait)
    assert {:auth, "tok123"} = next(s)
    assert {:attach, a} = next(s)
    push(s, {:attached, %{resumed: resumed, session: "default"}})
    {s, a}
  end

  defp push(s, term), do: :ok = :gen_tcp.send(s, Wire.encode(term))

  # next frame from the client on socket s (buffered per socket in the process dict)
  defp next(s, timeout \\ @wait) do
    case Process.get({:frames, s}, {[], ""}) do
      {[f | fs], rest} ->
        Process.put({:frames, s}, {fs, rest})
        f

      {[], rest} ->
        case :gen_tcp.recv(s, 0, timeout) do
          {:ok, data} ->
            {:ok, fs, rest} = Wire.decode(rest <> data, Wire.max_client_frame())
            Process.put({:frames, s}, {fs, rest})
            next(s, timeout)

          {:error, _} = err ->
            err
        end
    end
  end

  defp scene do
    pane = %Pane{id: 1, rect: %{x: 0, y: 0, w: 80, h: 23}, rows: {:inline, [{0, "row0"}]}}
    %{Notice.blank(@size) | panes: [pane]}
  end

  defp notice(scene) do
    Enum.find(Node.find(scene.chrome, [:status]).children, &(&1.id == :notice))
  end

  defp input(conn, seq, ev), do: send(conn, {:input, self(), seq, ev})

  test "attach sends auth then attach with the render size", ctx do
    start(ctx)
    {:ok, s} = :gen_tcp.accept(ctx.l, @wait)
    assert {:auth, "tok123"} = next(s)
    assert {:attach, a} = frame = next(s)
    assert :ok = Wire.validate_client_frame(frame)

    assert %{version: 1, kind: :term, size: @size, session: nil, target: :session, caps: %{}} =
             a

    assert a.client_id =~ ~r/^[0-9a-f]{32}$/
  end

  test "acks map back to Input seqs after renumbering", ctx do
    conn = start(ctx)
    {s, _} = handshake(ctx.l)
    input(conn, 7, Event.key("a"))
    assert {:input, 1, {:key, %{key: "a"}}} = next(s)
    input(conn, 8, Event.key("b"))
    assert {:input, 2, {:key, %{key: "b"}}} = next(s)
    push(s, {:ack, 1})
    assert_receive {:ack, 7}, @wait
    push(s, {:ack, 2})
    assert_receive {:ack, 8}, @wait
    # an unknown ack is ignored
    push(s, {:ack, 99})
    refute_receive {:ack, _}, 200
  end

  test "server frames other than acks go to Render", ctx do
    start(ctx)
    {s, _} = handshake(ctx.l)
    sc = scene()
    push(s, {:scene, sc})
    assert_receive {:scene, ^sc}, @wait
    push(s, {:rows, 1, 2, [{1, "r"}]})
    assert_receive {:rows, 1, 2, [{1, "r"}]}, @wait
  end

  test "disconnect shows a notice node in the status and reconnects with backoff", ctx do
    conn = start(ctx)
    {s, a1} = handshake(ctx.l)
    push(s, {:scene, scene()})
    assert_receive {:scene, _}, @wait
    :ok = :gen_tcp.close(s)

    assert_receive {:scene, sc}, @wait
    assert notice(sc).text =~ "reconnecting"
    # the cached scene drops its inline rows: they would overwrite newer ones
    assert [%{rows: {:inline, []}}] = sc.panes

    input(conn, 1, {:resize, %{cols: 100, rows: 30, cell_px: nil}})
    {s2, a2} = handshake(ctx.l, true)
    assert a2.client_id == a1.client_id
    assert a2.size == %{cols: 100, rows: 30}
    assert_receive {:scene, sc}, @wait
    assert notice(sc) == nil
    assert {:input, 1, {:resize, _}} = next(s2)
  end

  test "a failed connect shows a notice on a blank scene and retries", ctx do
    {:unix, path, token} = ctx.transport
    missing = Path.join(ctx.dir, "none.sock")
    start(ctx, transport: {:unix, missing, token})
    assert_receive {:scene, sc}, @wait
    assert sc.size == @size
    assert notice(sc).text =~ "reconnecting"
    # still retrying: a second notice after the backoff
    assert_receive {:scene, _}, @wait
    assert path != missing
  end

  test "unacked input is resent after attached", ctx do
    conn = start(ctx)
    {s, _} = handshake(ctx.l)
    input(conn, 1, Event.key("a"))
    assert {:input, 1, _} = next(s)
    :ok = :gen_tcp.close(s)
    {s2, _} = handshake(ctx.l, true)
    assert {:input, 1, {:key, %{key: "a"}}} = next(s2)
    push(s2, {:ack, 1})
    assert_receive {:ack, 1}, @wait
  end

  test "handoff begin holds input until attached", ctx do
    conn = start(ctx)
    {s, _} = handshake(ctx.l)
    push(s, {:handoff, %{phase: :begin}})
    assert_receive {:handoff, %{phase: :begin}}, @wait
    input(conn, 1, Event.key("a"))
    assert {:error, :timeout} = next(s, 300)
    push(s, {:attached, %{resumed: :handoff, session: "default"}})
    assert {:input, 1, {:key, %{key: "a"}}} = next(s)

    # aborted releases the held input without an attached
    push(s, {:handoff, %{phase: :released}})
    assert_receive {:handoff, %{phase: :released}}, @wait
    input(conn, 2, Event.key("b"))
    assert {:error, :timeout} = next(s, 300)
    push(s, {:handoff, %{phase: :aborted}})
    assert {:input, 2, {:key, %{key: "b"}}} = next(s)
    # input 1 was already sent and is not sent again
    assert {:error, :timeout} = next(s, 300)
  end

  test "refused stops via local_exit with its reason and does not reconnect", ctx do
    reason = reason_file(ctx)
    start(ctx)
    {:ok, s} = :gen_tcp.accept(ctx.l, @wait)
    push(s, {:refused, "bad token"})
    assert_receive :local_exit, @wait
    assert File.read!(reason) == "refused: bad token"
    assert {:error, :timeout} = :gen_tcp.accept(ctx.l, 500)
  end

  test "an ssh relay that exits nonzero before any attach ends the VM with its reason",
       ctx do
    reason = reason_file(ctx)
    ssh = Path.join(ctx.dir, "fake-ssh")
    File.write!(ssh, "#!/bin/sh\nexit 255\n")
    File.chmod!(ssh, 0o755)
    System.put_env("HERDR_LIVE_SSH", ssh)
    on_exit(fn -> System.delete_env("HERDR_LIVE_SSH") end)
    start(ctx, transport: {:ssh, "nosuchhost", nil})
    assert_receive :local_exit, @wait
    assert File.read!(reason) == "ssh relay to nosuchhost exited (255) before attaching"
  end

  test "a missing or empty token file says so and retries", ctx do
    {:unix, path, _} = ctx.transport
    empty = Path.join(ctx.dir, "empty.token")
    File.write!(empty, " \n")

    for token <- [Path.join(ctx.dir, "none.token"), empty] do
      _ = start(ctx, transport: {:unix, path, token})
      assert_receive {:scene, sc}, @wait
      assert notice(sc).text =~ "no client token at #{token}, reconnecting"
      :ok = stop_supervised(Conn)
      flush_scenes()
    end
  end

  test "a fresh session after an earlier attach discards the input typed while away", ctx do
    conn = start(ctx)
    {s, _} = handshake(ctx.l)
    input(conn, 1, Event.key("a"))
    assert {:input, 1, _} = next(s)
    :ok = :gen_tcp.close(s)
    input(conn, 2, Event.key("b"))
    {s2, _} = handshake(ctx.l, false)
    assert_receive {:ack, 1}, @wait
    assert_receive {:ack, 2}, @wait

    assert_receive {:notice,
                    %{level: :warning, text: "session restarted; 2 keystrokes discarded"}},
                   @wait

    assert {:error, :timeout} = next(s2, 300)
  end

  defp flush_scenes do
    receive do
      {:scene, _} -> flush_scenes()
    after
      0 -> :ok
    end
  end

  defp reason_file(ctx) do
    path = Path.join(ctx.dir, "reason")
    System.put_env("HERDR_LIVE_CLIENT_REASON", path)
    on_exit(fn -> System.delete_env("HERDR_LIVE_CLIENT_REASON") end)
    path
  end

  test "undecodable frame gives a notice and reconnects after the longest delay", ctx do
    start(ctx, backoff: {10, 1_000})
    {s, _} = handshake(ctx.l)
    push(s, {:scene, scene()})
    assert_receive {:scene, _}, @wait
    atom = "dynide_term_remote_no_such_atom_#{System.unique_integer([:positive])}"
    etf = <<131, 119, byte_size(atom), atom::binary>>

    # twice: the attach in between resets the backoff, a bad term must not
    Enum.reduce(1..2, s, fn _, s ->
      :ok = :gen_tcp.send(s, <<byte_size(etf)::32-big, etf::binary>>)
      assert_receive {:scene, sc}, @wait
      assert notice(sc).text =~ "cannot decode"
      assert {:error, :timeout} = :gen_tcp.accept(ctx.l, 500)
      {s, _} = handshake(ctx.l, true)
      s
    end)
  end

  test "pane mode handles the detach keys itself", ctx do
    conn = start(ctx, target: {:pane, 3, :control})
    {s, a} = handshake(ctx.l)
    assert a.target == {:pane, 3, :control}
    input(conn, 1, Event.key("b", [:ctrl]))
    assert_receive {:ack, 1}, @wait
    input(conn, 2, Event.key("x"))
    assert {:input, 1, {:key, %{key: "b", mods: [:ctrl]}}} = next(s)
    assert {:input, 2, {:key, %{key: "x"}}} = next(s)
    push(s, {:ack, 1})
    push(s, {:ack, 2})
    assert_receive {:ack, 2}, @wait

    input(conn, 3, Event.key("b", [:ctrl]))
    input(conn, 4, Event.key("q"))
    assert {:detach} = next(s)
    assert_receive :local_exit, @wait
  end

  test "ssh transport runs the relay command and sends no auth", ctx do
    out = Path.join(ctx.dir, "out")
    args = Path.join(ctx.dir, "args")
    frames = Path.join(ctx.dir, "frames")
    File.write!(frames, Wire.encode({:attached, %{resumed: false, session: "s"}}))
    ssh = Path.join(ctx.dir, "fake-ssh")

    File.write!(ssh, """
    #!/bin/sh
    echo "$@" > #{args}
    cat #{frames}
    exec cat > #{out}
    """)

    File.chmod!(ssh, 0o755)
    System.put_env("HERDR_LIVE_SSH", ssh)
    on_exit(fn -> System.delete_env("HERDR_LIVE_SSH") end)

    conn = start(ctx, transport: {:ssh, "box", "s"}, session: "s")
    input(conn, 1, Event.key("a"))

    frames =
      wait_until(fn ->
        with {:ok, bin} <- File.read(out),
             {:ok, [_, _] = fs, _} <- Wire.decode(bin, Wire.max_client_frame()),
             do: fs,
             else: (_ -> nil)
      end)

    assert [{:attach, %{session: "s"}}, {:input, 1, {:key, %{key: "a"}}}] = frames
    assert File.read!(args) =~ ~r/BatchMode=yes .*box herdr-live attach-relay/
  end

  test "an ssh relay that exits shows a notice and is respawned with the same client_id",
       ctx do
    d = ctx.dir
    ssh = Path.join(d, "fake-ssh")

    # run 1 attaches, reads the attach frame (exactly) and exits 3; run 2 stays and
    # records stdin (a relay that exits before any attach ends the VM instead)
    File.write!(Path.join(d, "frames"), Wire.encode({:attached, %{resumed: false, session: "s"}}))

    File.write!(ssh, """
    #!/bin/sh
    n=$(( $(cat #{d}/count 2>/dev/null || echo 0) + 1 ))
    echo $n > #{d}/count
    if [ $n = 1 ]; then
      cat #{d}/frames
      dd bs=1 count=4 of=#{d}/out.1 2>/dev/null
      len=$(od -An -tu1 #{d}/out.1 | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
      dd bs=1 count=$len 2>/dev/null >> #{d}/out.1
      exit 3
    fi
    exec cat > #{d}/out.$n
    """)

    File.chmod!(ssh, 0o755)
    System.put_env("HERDR_LIVE_SSH", ssh)
    on_exit(fn -> System.delete_env("HERDR_LIVE_SSH") end)

    conn = start(ctx, transport: {:ssh, "box", nil})
    assert_receive {:scene, sc}, @wait
    assert notice(sc).text =~ "ssh relay exited (3)"

    attach = fn path ->
      wait_until(fn ->
        with {:ok, bin} <- File.read(path),
             {:ok, [{:attach, a} | _], _} <- Wire.decode(bin, Wire.max_client_frame()),
             do: a,
             else: (_ -> nil)
      end)
    end

    a1 = attach.(Path.join(d, "out.1"))
    a2 = attach.(Path.join(d, "out.2"))
    assert a1.client_id == a2.client_id
    assert Process.alive?(conn)
  end

  defp wait_until(fun, n \\ 300) do
    cond do
      v = fun.() -> v
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, n - 1)
    end
  end
end
