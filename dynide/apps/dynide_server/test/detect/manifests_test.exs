defmodule DynideServer.Detect.ManifestsTest do
  # reload/0 reads the application env and writes :persistent_term
  use ExUnit.Case, async: false

  alias DynideServer.Detect.Manifests

  @moduletag :tmp_dir

  defp manifest(id, contains, extra \\ ""),
    do:
      "id = \"#{id}\"\nversion = \"1.0\"\n#{extra}[[rules]]\nid = \"r\"\nstate = \"idle\"\ncontains = ['#{contains}']\n"

  setup %{tmp_dir: dir} do
    bundled = Path.join(dir, "bundled")
    overrides = Path.join(dir, "agent-detection")
    File.mkdir_p!(bundled)
    File.mkdir_p!(overrides)

    File.write!(
      Path.join(bundled, "alpha.toml"),
      manifest("alpha", "a", "aliases = [\"alpha-cli\"]\n")
    )

    File.write!(Path.join(bundled, "beta-file.toml"), manifest("beta", "b"))
    %{bundled: bundled, overrides: overrides}
  end

  test "bundled only", %{bundled: b, overrides: o} do
    assert %{"alpha" => alpha, "beta" => beta} = Manifests.load(b, o)
    assert %{source: :bundled, path: nil, version: "1.0", warning: nil, error: nil} = alpha
    assert alpha.manifest.id == "alpha"
    assert beta.source == :bundled
  end

  test "a valid override wins", %{bundled: b, overrides: o} do
    path = Path.join(o, "alpha.toml")
    File.write!(path, manifest("other", "override", "aliases = [\"alpha\"]\n"))
    assert %{source: :override, path: ^path, warning: nil} = e = Manifests.load(b, o)["alpha"]
    assert [%{gate: %{contains: ["override"]}}] = e.manifest.rules
  end

  test "an override whose id is an alias spelling of the label wins", %{bundled: b, overrides: o} do
    File.write!(Path.join(b, "claude.toml"), manifest("claude", "a"))
    File.write!(Path.join(o, "claude.toml"), manifest("claude-code", "override"))
    assert %{source: :override, warning: nil} = Manifests.load(b, o)["claude"]
  end

  test "an invalid override keeps bundled with a warning", %{bundled: b, overrides: o} do
    File.write!(Path.join(o, "alpha.toml"), "id = \"alpha\"\n")
    e = Manifests.load(b, o)["alpha"]
    assert e.source == :bundled
    assert e.warning =~ ~r/^ignored override .*alpha\.toml because it could not be loaded: /
  end

  test "an override with a mismatched id keeps bundled", %{bundled: b, overrides: o} do
    File.write!(Path.join(o, "alpha.toml"), manifest("gamma", "g"))
    e = Manifests.load(b, o)["alpha"]
    assert e.source == :bundled
    assert e.warning =~ "manifest id gamma does not match alpha"
  end

  test "a broken bundled file sets error and leaves other agents alone", %{
    bundled: b,
    overrides: o
  } do
    File.write!(Path.join(b, "beta-file.toml"), "id = \"beta\"\nrules = []\n")
    entries = Manifests.load(b, o)
    assert %{manifest: nil, error: "bundled beta manifest is invalid: " <> _} = entries["beta"]
    assert entries["alpha"].manifest
  end

  describe "store" do
    setup %{tmp_dir: dir} do
      saved = Application.get_env(:dynide_server, :config_path)
      Application.put_env(:dynide_server, :config_path, Path.join(dir, "config.toml"))

      on_exit(fn ->
        if saved,
          do: Application.put_env(:dynide_server, :config_path, saved),
          else: Application.delete_env(:dynide_server, :config_path)

        Manifests.reload()
      end)
    end

    test "reload/0 picks up a changed override file", %{overrides: o} do
      assert Manifests.override_dir() == o
      Manifests.reload()
      assert %{source: :bundled} = Manifests.get("claude")

      File.write!(Path.join(o, "claude.toml"), manifest("claude", "x"))
      summaries = Manifests.reload()
      assert %{source: :override} = Manifests.get("claude")

      assert %{
               "source" => "override",
               "path" => path,
               "version" => "1.0",
               "warning" => nil,
               "error" => nil
             } =
               Enum.find(summaries, &(&1["agent"] == "claude"))

      assert path == Path.join(o, "claude.toml")
      assert summaries == Manifests.summaries()
      assert Manifests.get("nope") == nil
    end
  end
end
