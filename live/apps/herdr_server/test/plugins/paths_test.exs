defmodule HerdrServer.Plugins.PathsTest do
  use ExUnit.Case, async: false

  alias HerdrServer.Plugins.Paths

  setup do
    base = Path.join(System.tmp_dir!(), "paths-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:herdr_server, :plugins)

    Application.put_env(:herdr_server, :plugins,
      config_dir: base <> "/c",
      state_dir: base <> "/s"
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:herdr_server, :plugins, prev),
        else: Application.delete_env(:herdr_server, :plugins)

      File.rm_rf!(base)
    end)

    %{base: base}
  end

  test "encode escapes everything unsafe" do
    assert Paths.encode("../../x") == "..%2F..%2Fx"
    assert Paths.encode("CON") == "%43%4F%4E"
    assert Paths.encode("con") == "%con"
    assert Paths.encode("") == "%plugin"
    assert Paths.encode("a.") == "a%2E"
    assert Paths.encode("Example") == "%45xample"
    assert Paths.encode("example:a") == "example%3Aa"
    assert Paths.encode("examples.agent-telegram-notify") == "examples.agent-telegram-notify"
    assert Paths.encode("é") == "%C3%A9"
  end

  test "long ids are clipped to 120 and stay distinct" do
    a = Paths.encode(String.duplicate("a", 200))
    assert String.length(a) == 120
    refute a == Paths.encode(String.duplicate("a", 201))
  end

  test "layout under the overridden bases", %{base: base} do
    assert Paths.registry() == base <> "/c/plugins.json"
    assert Paths.plugin_config_dir("x.y") == base <> "/c/plugins/config/x.y"
    assert Paths.plugin_state_dir("x.y") == base <> "/s/plugins/x.y"
    assert Paths.plugin_config_dir("../x") |> Path.dirname() == base <> "/c/plugins/config"
  end

  test "installations dir is readable slug plus 12 hex of sha256" do
    dir = Paths.installations_dir("example.worktree-bootstrap")

    hash =
      :crypto.hash(:sha256, "example.worktree-bootstrap")
      |> binary_part(0, 6)
      |> Base.encode16(case: :lower)

    assert Path.basename(dir) == "example.worktree-bootstrap-" <> hash
    assert Path.dirname(dir) |> Path.basename() == "github-installations"
    assert Path.basename(Paths.installations_dir("..")) =~ ~r/\Aplugin-[0-9a-f]{12}\z/
    assert Path.basename(Paths.installations_dir("con.example")) =~ ~r/\Acon-example-/
    refute Paths.installations_dir("a:b") == Paths.installations_dir("a_b")
  end

  test "ensure_user_dirs creates both", %{base: base} do
    assert :ok = Paths.ensure_user_dirs("x.y")
    assert File.dir?(base <> "/c/plugins/config/x.y")
    assert File.dir?(base <> "/s/plugins/x.y")
  end

  test "defaults follow XDG at call time" do
    Application.delete_env(:herdr_server, :plugins)
    old = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", "/xdg/c")

    on_exit(fn ->
      if old,
        do: System.put_env("XDG_CONFIG_HOME", old),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    assert Paths.config_dir() == "/xdg/c/herdr-live"
  end
end
