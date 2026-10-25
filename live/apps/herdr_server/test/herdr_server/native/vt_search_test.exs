defmodule HerdrServer.Native.VtSearchTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Native.Vt

  @text "foo bar\r\nnone\r\nx bar bar\r\nFOO\r\nbarbar"

  defp opts(from, dir, more \\ %{}),
    do:
      Map.merge(
        %{max_rows: 20_000, max_matches: 1000, case_sensitive: true, from: from, direction: dir},
        more
      )

  defp vt do
    {:ok, vt} = Vt.new(20, 5, 10_000)
    Vt.feed(vt, @text)
    vt
  end

  test "forward and backward, in reading order" do
    vt = vt()

    assert Vt.search(vt, "bar", opts(0, :forward)) ==
             {:ok, [{0, 4, 3}, {2, 2, 3}, {2, 6, 3}, {4, 0, 3}, {4, 3, 3}], :done}

    assert Vt.search(vt, "bar", opts(2, :backward)) ==
             {:ok, [{2, 2, 3}, {2, 6, 3}, {0, 4, 3}], :done}
  end

  test "case folding is the caller's choice" do
    vt = vt()
    assert {:ok, [{3, 0, 3}], :done} = Vt.search(vt, "FOO", opts(0, :forward))

    assert {:ok, [{0, 0, 3}, {3, 0, 3}], :done} =
             Vt.search(vt, "FOO", opts(0, :forward, %{case_sensitive: false}))
  end

  test "max_matches and max_rows return the next row" do
    vt = vt()

    assert Vt.search(vt, "bar", opts(0, :forward, %{max_matches: 2})) ==
             {:ok, [{0, 4, 3}, {2, 2, 3}, {2, 6, 3}], 3}

    assert Vt.search(vt, "bar", opts(0, :forward, %{max_rows: 2})) == {:ok, [{0, 4, 3}], 2}
    assert Vt.search(vt, "bar", opts(3, :backward, %{max_rows: 1})) == {:ok, [], 2}
  end

  test "wide characters count in cells" do
    {:ok, vt} = Vt.new(20, 5, 10_000)
    Vt.feed(vt, "中x 中文")
    assert {:ok, [{0, 2, 1}], _} = Vt.search(vt, "x", opts(0, :forward))
    assert {:ok, [{0, 4, 4}], _} = Vt.search(vt, "中文", opts(0, :forward))
  end

  test "the fake kernel answers like the real one (ASCII; the fake has no wide cells)" do
    real = vt()
    {:ok, fake} = Fake.Vt.new(20, 5, 0)
    :ok = Fake.Vt.write_sync(fake, @text)

    for q <- ["bar", "FOO", "o", "x b", "zz"],
        from <- 0..5,
        dir <- [:forward, :backward],
        more <- [%{}, %{case_sensitive: false}, %{max_matches: 1}, %{max_rows: 2}] do
      o = opts(from, dir, more)
      assert Fake.Vt.search(fake, q, o) == Vt.search(real, q, o), inspect({q, o})
    end
  end

  test "bad options raise" do
    vt = vt()

    for bad <- [%{max_rows: 0}, %{max_matches: 0}, %{direction: :up}, %{case_sensitive: 1}] do
      assert_raise FunctionClauseError, fn ->
        Vt.search(vt, "x", Map.merge(opts(0, :forward), bad))
      end
    end
  end
end
