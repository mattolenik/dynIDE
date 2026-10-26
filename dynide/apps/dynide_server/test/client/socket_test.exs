defmodule DynideServer.Client.SocketTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import DynideServer.Test.WireClient

  alias DynideScene.{Event, Scene, Wire}
  alias DynideServer.Client.Socket

  setup do
    setup_listener()
  end

  defp attached!(s) do
    assert {:attached, %{resumed: false, session: "default"}} = recv_frame(s)
    s
  end

  defp closed?(s), do: recv_frame(s) == {:error, :closed}

  test "socket and token are 0600; the token is reused", ctx do
    assert File.stat!(ctx.token_path).mode |> Bitwise.band(0o777) == 0o600
    assert byte_size(ctx.token) == 64
    assert Socket.token(ctx.token_path) == ctx.token
    assert File.stat!(ctx.path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "an empty or whitespace-only token file is replaced, not trusted", ctx do
    for junk <- ["", " \n\t"] do
      path = Path.join(Path.dirname(ctx.token_path), "junk.token")
      File.write!(path, junk)
      t = Task.async(fn -> Socket.token(path) end)
      assert {:ok, token} = Task.yield(t, 2000)
      assert token =~ ~r/\A[0-9a-f]{64}\z/
      assert File.read!(path) == token
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert Path.wildcard(path <> ".*.tmp") == []
      File.rm!(path)
    end
  end

  test "an empty server token refuses even an empty auth", ctx do
    lpath = Path.join(Path.dirname(ctx.token_path), "h.sock")
    opts = [{:ifaddr, {:local, lpath}}, :binary, packet: :raw, active: false]
    {:ok, l} = :gen_tcp.listen(0, opts)
    c = connect(lpath)
    {:ok, a} = :gen_tcp.accept(l, 1000)
    pid = spawn(Socket, :handshake, [%{token: "", session: "default"}])
    :ok = :gen_tcp.controlling_process(a, pid)
    send(pid, {:socket, a})
    :ok = send_frame(c, {:auth, ""})
    assert recv_frame(c) == {:refused, "bad token"}
  end

  test "attach yields attached, then a scene with inline rows", ctx do
    s = attached!(attach(ctx))
    assert {:scene, %Scene{panes: [%{rows: {:inline, rows}, rect: rect}]} = sc} = recv_frame(s)
    assert Scene.validate(sc) == :ok
    assert length(rows) == rect.h
  end

  test "bad token is refused and closed", ctx do
    s = attach(%{ctx | token: "nope"})
    assert recv_frame(s) == {:refused, "bad token"}
    assert closed?(s)
  end

  test "a first frame other than auth is refused", ctx do
    s = connect(ctx.path)
    :ok = send_frame(s, {:attach, attach_info()})
    assert recv_frame(s) == {:refused, "bad token"}
    assert closed?(s)
  end

  test "wrong session refused", ctx do
    s = attach(ctx, session: "nope")
    assert recv_frame(s) == {:refused, "no session nope here (this server runs default)"}
    assert closed?(s)
    attached!(attach(ctx, session: "default"))
  end

  test "another protocol version refused", ctx do
    s = attach(ctx, version: 99)
    assert recv_frame(s) == {:refused, "protocol version"}
    assert closed?(s)
  end

  test "invalid frame gets a notice and the connection stays", ctx do
    s = attached!(attach(ctx))
    :ok = send_frame(s, {:input, 1, {:bogus}})

    assert {:notice, %{level: :warning, text: "frame rejected: " <> _}} =
             recv_until(s, &match?({:notice, _}, &1))

    :ok = send_frame(s, {:input, 2, Event.key("a")})
    assert {:ack, 2} = recv_until(s, &match?({:ack, _}, &1))
  end

  test "frame with a pid is rejected", ctx do
    s = attached!(attach(ctx))
    :ok = send_frame(s, {:input, 1, {:paste, self()}})

    assert {:notice, %{text: "frame rejected: not plain data"}} =
             recv_until(s, &match?({:notice, _}, &1))

    :ok = send_frame(s, {:input, 2, Event.key("a")})
    assert {:ack, 2} = recv_until(s, &match?({:ack, _}, &1))
  end

  test "oversize frame closes only that connection; another client keeps working", ctx do
    a = attached!(attach(ctx))
    b = attached!(attach(ctx))
    :ok = :gen_tcp.send(a, <<Wire.max_client_frame() + 1::32-big, 0>>)
    assert recv_closed(a) == :closed
    :ok = send_frame(b, {:input, 1, Event.key("a")})
    assert {:ack, 1} = recv_until(b, &match?({:ack, _}, &1))
  end

  test "an undecodable frame closes the connection", ctx do
    a = attached!(attach(ctx))
    :ok = :gen_tcp.send(a, <<3::32-big, 1, 2, 3>>)
    assert recv_closed(a) == :closed
  end

  test "partial frame then close", ctx do
    b = attached!(attach(ctx))
    # during the handshake
    s = connect(ctx.path)
    :ok = :gen_tcp.send(s, <<0, 0, 1>>)
    :gen_tcp.close(s)
    # after attach: a header and half a body
    a = attached!(attach(ctx))
    :ok = :gen_tcp.send(a, <<100::32-big, 1, 2, 3>>)
    :gen_tcp.close(a)

    :ok = send_frame(b, {:input, 1, Event.key("a")})
    assert {:ack, 1} = recv_until(b, &match?({:ack, _}, &1))
    attached!(attach(ctx))
  end

  test "a silent connection is closed after the handshake timeout", ctx do
    s = connect(ctx.path)
    assert recv_frame(s, 8000) == {:error, :closed}
  end

  test "a handshake frame over 64 KiB closes the connection", ctx do
    s = connect(ctx.path)
    :ok = :gen_tcp.send(s, <<65_537::32-big, 0>>)
    assert recv_closed(s) == :closed
  end

  test "an input seq from 2^62 is rejected", ctx do
    s = attached!(attach(ctx))
    :ok = send_frame(s, {:input, 4_611_686_018_427_387_904, Event.key("a")})

    assert {:notice, %{text: "frame rejected: input: wire_seq too large"}} =
             recv_until(s, &match?({:notice, _}, &1))

    :ok = send_frame(s, {:input, 1, Event.key("a")})
    assert {:ack, 1} = recv_until(s, &match?({:ack, _}, &1))
  end
end
