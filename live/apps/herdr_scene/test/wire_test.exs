defmodule HerdrScene.WireTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Wire

  defp bin(frames), do: frames |> Enum.map(&Wire.encode/1) |> IO.iodata_to_binary()

  test "round trip of 3 frames in one buffer" do
    fs = [{:detach}, {:caps, %{a: 1}}, {:input, 3, {:paste, "x"}}]
    assert {:ok, ^fs, ""} = Wire.decode(bin(fs), 1000)
  end

  test "a buffer cut at every offset yields each frame once, plus the rest" do
    fs = [{:caps, %{a: 1}}, {:detach}]
    b = bin(fs)
    first = byte_size(bin([hd(fs)]))

    for n <- 0..byte_size(b) do
      <<head::binary-size(^n), tail::binary>> = b
      assert {:ok, got, rest} = Wire.decode(head, 1000)
      assert {:ok, got2, ""} = Wire.decode(rest <> tail, 1000)
      assert got ++ got2 == fs
      assert (n >= first and got != []) or (n < first and got == [])
    end
  end

  test "partial and oversized frames" do
    assert {:ok, [], <<0, 0, 0, 10, 1, 2>>} = Wire.decode(<<0, 0, 0, 10, 1, 2>>, 100)
    assert {:error, :too_large} = Wire.decode(<<0, 0, 0, 200, 1>>, 100)
  end

  test "an unknown atom is a bad term" do
    bad = swap("m16_never_seen_atom_xyz")
    assert {:error, :bad_term} = Wire.decode(<<byte_size(bad)::32, bad::binary>>, 1000)
  end

  # build an ETF atom whose text was never interned in this VM
  defp swap(text) do
    name = text <> "_" <> Integer.to_string(System.unique_integer([:positive]))
    <<131, 119, byte_size(name), name::binary>>
  end

  test "paths" do
    assert %{
             socket: "/h/.local/state/herdr-live/client.sock",
             api: "/h/.local/state/herdr-live/api.sock"
           } =
             Wire.paths(%{}, "/h")

    p = Wire.paths(%{"HERDR_LIVE_API" => "/t/api.sock"}, "/h")
    assert p.socket == "/t/client.sock" and p.token == "/t/client.token"

    p =
      Wire.paths(
        %{"HERDR_LIVE_CLIENT_SOCK" => "/c/s.sock", "HERDR_LIVE_API" => "/t/api.sock"},
        "/h"
      )

    assert p.socket == "/c/s.sock" and p.token == "/c/client.token"

    assert Wire.paths(%{"HERDR_LIVE_API" => "", "XDG_STATE_HOME" => "/x"}, "/h").api ==
             "/x/herdr-live/api.sock"
  end

  @attach %{
    version: 1,
    client_id: "c",
    session: nil,
    kind: :term,
    size: %{cols: 80, rows: 24},
    cell_px: nil,
    caps: %{},
    target: :session
  }

  test "client frame validation" do
    ev = {:paste, "x"}

    ok = [
      {:auth, "t"},
      {:attach, @attach},
      {:attach, %{@attach | target: {:pane, 2, :control}}},
      {:input, 0, ev},
      {:caps, %{}},
      {:detach}
    ]

    for f <- ok, do: assert(:ok = Wire.validate_client_frame(f), inspect(f))

    bad = [
      {:attach, Map.delete(@attach, :target)},
      {:attach, %{@attach | target: {:pane, 0, :observe}}},
      {:input, -1, ev},
      {:bogus, 1}
    ]

    for f <- bad, do: assert({:error, _} = Wire.validate_client_frame(f), inspect(f))
  end

  test "server frame validation" do
    for f <- [
          {:attached, %{resumed: true, session: "s"}},
          {:attached, %{resumed: :handoff, session: "s"}},
          {:refused, "bad token"},
          {:ack, 1},
          {:bell, 1}
        ],
        do: assert(:ok = Wire.validate_server_frame(f), inspect(f))

    assert {:error, _} = Wire.validate_server_frame({:attached, %{resumed: 1, session: "s"}})
  end
end
