defmodule HerdrServer.Detect.WatcherTest do
  # swaps the :config_path app env and writes :persistent_term
  use ExUnit.Case, async: false

  alias HerdrServer.Detect.{Manifests, Watcher}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    old = Application.get_env(:herdr_server, :config_path)
    Application.put_env(:herdr_server, :config_path, Path.join(dir, "config.toml"))

    on_exit(fn ->
      Application.put_env(:herdr_server, :config_path, old)
      Manifests.reload()
    end)
  end

  test "a saved override is loaded", %{tmp_dir: dir} do
    start_supervised!(Watcher)
    # creates the override dir; let the backend arm before writing
    assert File.dir?(Path.join(dir, "agent-detection"))
    Process.sleep(300)
    assert Manifests.get("pi").source == :bundled

    File.write!(Path.join([dir, "agent-detection", "pi.toml"]), """
    id = "pi"
    version = "9"
    [[rules]]
    id = "r"
    state = "idle"
    contains = ["x"]
    """)

    assert wait(fn -> Manifests.get("pi").source == :override end)
  end

  defp wait(fun, n \\ 40) do
    cond do
      fun.() -> true
      n == 0 -> false
      true -> Process.sleep(50) && wait(fun, n - 1)
    end
  end
end
