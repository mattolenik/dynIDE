defmodule HerdrServer.Native.LinkTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Native.Link

  # Short path: macOS caps unix socket paths at 104 bytes.
  setup do
    path = "/tmp/hl-#{System.unique_integer([:positive])}.sock"
    {:ok, l} = :gen_tcp.listen(0, ifaddr: {:local, path}, mode: :binary, active: false)

    on_exit(fn ->
      :gen_tcp.close(l)
      File.rm(path)
    end)

    {:ok, link} = Link.connect(path, self())
    {:ok, peer} = :gen_tcp.accept(l, 5_000)
    %{link: link, peer: peer}
  end

  test "hello frame reaches a listener", %{link: link, peer: peer} do
    assert Link.send(link, Link.kind(:hello), <<5::64, 123::32>>, []) == :ok
    assert :gen_tcp.recv(peer, 18, 5_000) == {:ok, <<14::32, 0x01, 0, 5::64, 123::32>>}
  end

  test "frames from the peer arrive as messages", %{link: link, peer: peer} do
    :ok = :gen_tcp.send(peer, <<2::32, 0x41, 0>>)
    assert_receive {:herdr_link, ^link, 0x41, "", []}, 5_000
  end

  test "peer close sends closed once", %{link: link, peer: peer} do
    :ok = :gen_tcp.close(peer)
    assert_receive {:herdr_link_closed, ^link, :eof}, 5_000
    refute_receive {:herdr_link_closed, _, _}, 100
    assert {:error, _} = Link.send(link, Link.kind(:fresh), "", [])
  end

  test "close shuts the link down", %{link: link} do
    assert Link.close(link) == :ok
    assert_receive {:herdr_link_closed, ^link, :eof}, 5_000
    assert Link.send(link, Link.kind(:drop), Link.frame_key("k", ""), []) == {:error, :closed}
  end

  test "frame_key refuses a key its u16 length cannot carry" do
    assert IO.iodata_length(Link.frame_key(String.duplicate("k", 65_535), "")) == 65_537
    assert_raise ArgumentError, fn -> Link.frame_key(String.duplicate("k", 65_536), "") end
  end

  test "keys roundtrip" do
    assert "k1" |> Link.frame_key("blob") |> IO.iodata_to_binary() |> Link.parse_key() ==
             {"k1", "blob"}

    assert Link.parse_key(<<0, 9, 1>>) == :error
  end
end
