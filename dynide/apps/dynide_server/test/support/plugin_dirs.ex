defmodule DynideServer.Test.PluginDirs do
  @moduledoc "Test helper: points `Plugins.Paths` at a fresh tmp dir, removed on exit."

  import ExUnit.Callbacks, only: [on_exit: 1]

  @script Path.expand("../../../../scripts/plugin_examples.sh", __DIR__)

  @doc """
  herdr's example plugins at the pinned commit, fetched into a cache (ruling R7: no upstream
  licence, so never vendored). Tests using them are tagged `:examples`; `test_helper.exs`
  excludes that tag when this returns `:skip` (no cache and no network, or DYNIDE_OFFLINE=1).
  """
  @spec fetch_examples() :: {:ok, Path.t()} | :skip
  def fetch_examples do
    case System.cmd(@script, [], stderr_to_stdout: false) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :skip
    end
  end

  @spec examples() :: Path.t()
  def examples do
    {:ok, dir} = fetch_examples()
    dir
  end

  @doc "Sets `:plugins` config/state dirs (plus `extra`) under a new tmp base; returns the base."
  @spec use_tmp(keyword()) :: Path.t()
  def use_tmp(extra \\ []) do
    base =
      Path.join(System.tmp_dir!(), "hlplug#{System.pid()}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    prev = Application.get_env(:dynide_server, :plugins)

    Application.put_env(
      :dynide_server,
      :plugins,
      [config_dir: base <> "/c", state_dir: base <> "/s"] ++ extra
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dynide_server, :plugins, prev),
        else: Application.delete_env(:dynide_server, :plugins)

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
