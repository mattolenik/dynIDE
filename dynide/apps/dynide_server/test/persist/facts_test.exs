defmodule DynideServer.Persist.FactsTest do
  use ExUnit.Case, async: false

  alias DynideServer.Kernel.Fake
  alias DynideServer.{Mirror, Persist.Facts}
  alias DynideServer.Pane.Rows

  # pane ids far above anything the running Store allocates
  @a 900_001
  @b 900_002

  setup do
    {:ok, kid} =
      Fake.Keeper.open(%{
        cmd: "/bin/zsh",
        args: ["-l"],
        env: [],
        cwd: "/spawn/dir",
        cols: 20,
        rows: 4,
        max_scrollback: 100,
        subscriber: nil
      })

    Rows.put_kernel_id(@a, kid)

    on_exit(fn ->
      Rows.delete(@a)
      Rows.delete(@b)
      Fake.Keeper.close(kid)
    end)

    {:ok, res} = Fake.Keeper.lookup(kid)
    {:ok, res: res}
  end

  defp app(ids), do: %{session: %{panes: Map.new(ids, &{&1, %{title: nil}})}}

  test "cwd from the pty, then its new value; command from the keeper row", %{res: res} do
    assert %{@a => %{cwd: "/spawn/dir", command: ["/bin/zsh", "-l"], hidden: false}} =
             Facts.collect(app([@a]))

    Fake.Pty.set_cwd(res.pty, "/moved")
    assert %{@a => %{cwd: "/moved"}} = Facts.collect(app([@a]))
  end

  test "cwd/1 reads one pane's pty cwd; an unmapped pane has none" do
    assert Facts.cwd(@a) == "/spawn/dir"
    assert Facts.cwd(@b) == nil
  end

  test "a nil cwd keeps the previous one", %{res: res} do
    prev = Facts.collect(app([@a]))
    Fake.Pty.set_cwd(res.pty, nil)
    assert %{@a => %{cwd: "/spawn/dir"}} = Facts.collect(app([@a]), prev)
  end

  test "a pty without a cwd falls back to the osc cwd", %{res: res} do
    Fake.Pty.set_cwd(res.pty, nil)
    DynideServer.Pane.Facts.put(@a, %{cwd: "/tmp"})
    on_exit(fn -> DynideServer.Pane.Facts.delete(@a) end)
    assert %{@a => %{cwd: "/tmp"}} = Facts.collect(app([@a]))
  end

  test "hidden comes from the mirror" do
    Mirror.put({:pane, @a}, %{hidden: true})
    assert %{@a => %{hidden: true}} = Facts.collect(app([@a]))
  end

  test "an unmapped pane keeps prev, or nil values" do
    prev = %{@b => %{cwd: "/old", command: ["vim"], hidden: true}}
    assert Facts.collect(app([@b]), prev) == prev
    assert Facts.collect(app([@b])) == %{@b => %{cwd: nil, command: nil, hidden: false}}
  end

  test "tail and gen", %{res: res} do
    assert Facts.tail(@b, 10) == nil
    assert Facts.tail(@a, 0) == nil
    Fake.Vt.write_sync(res.vt, "hello")
    assert Facts.tail(@a, 10) =~ "hello"

    assert Facts.gen(@b) == nil
    Rows.put(@b, 7, {}, nil)
    assert Facts.gen(@b) == 7
  end
end
