defmodule HerdrServer.Test.PluginDirs do
  @moduledoc "Test helper: points `Plugins.Paths` at a fresh tmp dir, removed on exit."

  import ExUnit.Callbacks, only: [on_exit: 1]

  @examples Path.expand("../../../../../vendor/herdr-plugin-examples", __DIR__)

  @spec examples() :: Path.t()
  def examples, do: @examples

  @doc "Sets `:plugins` config/state dirs (plus `extra`) under a new tmp base; returns the base."
  @spec use_tmp(keyword()) :: Path.t()
  def use_tmp(extra \\ []) do
    base = Path.join(System.tmp_dir!(), "hlplug#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    prev = Application.get_env(:herdr_server, :plugins)

    Application.put_env(
      :herdr_server,
      :plugins,
      [config_dir: base <> "/c", state_dir: base <> "/s"] ++ extra
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:herdr_server, :plugins, prev),
        else: Application.delete_env(:herdr_server, :plugins)

      File.rm_rf!(base)
    end)

    base
  end

  @doc "Writes a minimal manifest for `id` into `dir` (created); returns `dir`."
  @spec plugin(Path.t(), String.t(), String.t()) :: Path.t()
  def plugin(dir, id, extra \\ "") do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "herdr-plugin.toml"), """
    id = "#{id}"
    name = "T"
    version = "1.0.0"
    min_herdr_version = "0.7.0"
    platforms = ["linux", "macos"]
    #{extra}
    """)

    dir
  end
end
