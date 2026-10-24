defmodule HerdrServer.Reload.NoticesTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Reload.Notices

  test "broadcast without registry is a no-op" do
    assert Notices.broadcast({:loaded, 1, [Foo]}) == :ok
  end

  describe "with registry" do
    setup do
      start_supervised!(Notices)
      :ok
    end

    test "subscriber receives events" do
      Notices.subscribe()
      Notices.broadcast({:loaded, 1, [Foo]})
      assert_receive {:herdr_reload, {:loaded, 1, [Foo]}}
    end

    test "all subscribers receive events" do
      parent = self()

      pids =
        for _ <- 1..2 do
          spawn_link(fn ->
            Notices.subscribe()
            send(parent, {:ready, self()})

            receive do
              msg -> send(parent, {:got, self(), msg})
            end
          end)
        end

      for pid <- pids, do: assert_receive({:ready, ^pid})
      Notices.broadcast(:x)
      for pid <- pids, do: assert_receive({:got, ^pid, {:herdr_reload, :x}})
    end
  end
end
