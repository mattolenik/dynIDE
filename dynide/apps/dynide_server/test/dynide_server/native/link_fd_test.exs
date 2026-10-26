defmodule DynideServer.Native.LinkFdTest do
  use ExUnit.Case, async: true

  alias DynideServer.Native.Link

  test "a socket fd survives dup, close, take and fdopen" do
    path = "/tmp/hlf#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    on_exit(fn -> :gen_tcp.close(l) && File.rm(path) end)

    {:ok, c} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    {:ok, accepted} = :gen_tcp.accept(l, 5_000)

    {:ok, n} = :inet.getfd(accepted)
    {:ok, fd} = Link.fd_dup(n)
    :ok = :gen_tcp.close(accepted)

    {:ok, raw} = Link.fd_take(fd)
    assert {:error, :consumed} = Link.fd_take(fd)
    {:ok, s} = :gen_tcp.fdopen(raw, [:binary, :local, active: false])

    :ok = :gen_tcp.send(c, "ping")
    assert {:ok, "ping"} = :gen_tcp.recv(s, 4, 5_000)
    :ok = :gen_tcp.send(s, "pong")
    assert {:ok, "pong"} = :gen_tcp.recv(c, 4, 5_000)
  end

  test "an fdopen'd port never closes its fd: fd_close does" do
    path = "/tmp/hlf#{System.pid()}-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)
    on_exit(fn -> :gen_tcp.close(l) && File.rm(path) end)
    {:ok, c} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    {:ok, accepted} = :gen_tcp.accept(l, 5_000)
    {:ok, n} = :inet.getfd(accepted)
    {:ok, fd} = Link.fd_dup(n)
    :ok = :gen_tcp.close(accepted)

    {:ok, raw} = Link.fd_raw(fd)
    {:ok, s} = :gen_tcp.fdopen(raw, [:binary, :local, active: false])
    :ok = :gen_tcp.close(s)
    assert {:error, :timeout} = :gen_tcp.recv(c, 0, 200)
    assert :ok = Link.fd_close(fd)
    assert {:error, :consumed} = Link.fd_close(fd)
    assert {:error, :closed} = :gen_tcp.recv(c, 0, 5_000)
  end

  test "fd_dup rejects a negative fd" do
    assert {:error, _} = Link.fd_dup(-1)
  end
end
