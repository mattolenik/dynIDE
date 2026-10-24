defmodule HerdrReload.WatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HerdrReload.Watcher

  setup do
    dir = Path.join(System.tmp_dir!(), "watcher_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp start(dir, extra \\ []) do
    test = self()

    pid =
      start_supervised!({Watcher, [dirs: [dir], on_batch: &send(test, {:batch, &1})] ++ extra})

    # let the OS backend arm before the first write
    Process.sleep(300)
    pid
  end

  defp names(paths), do: Enum.map(paths, &Path.basename/1)

  test "two quick writes make one batch with both paths", %{dir: dir} do
    start(dir)
    File.write!(Path.join(dir, "a.ex"), "1")
    Process.sleep(10)
    File.write!(Path.join(dir, "b.ex"), "2")
    assert_receive {:batch, paths}, 2000
    assert names(paths) == ["a.ex", "b.ex"]
    refute_receive {:batch, _}, 300
  end

  test "a later write makes a second batch", %{dir: dir} do
    start(dir)
    File.write!(Path.join(dir, "a.ex"), "1")
    assert_receive {:batch, _}, 2000
    File.write!(Path.join(dir, "a.ex"), "22")
    assert_receive {:batch, paths}, 2000
    assert names(paths) == ["a.ex"]
  end

  test "irrelevant extensions are ignored", %{dir: dir} do
    start(dir)
    File.write!(Path.join(dir, "a.ex.swp"), "1")
    refute_receive {:batch, _}, 500
  end

  test "a stale fire message does not call on_batch", %{dir: dir} do
    pid = start(dir)
    # pre-fix and current fire shapes, neither from the live timer
    send(pid, :fire)
    send(pid, {:timeout, make_ref(), :fire})
    refute_receive {:batch, _}, 300
  end

  test "backend failure returns :ignore with a warning", %{dir: dir} do
    log =
      capture_log(fn ->
        assert Watcher.start_link(dirs: [dir], backend_opts: [backend: :nonexistent]) == :ignore
      end)

    assert log =~ "reload watcher"
  end
end
