defmodule HerdrServer.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Plugins.Manifest

  @examples Path.expand("../../../../../vendor/herdr-plugin-examples", __DIR__)

  @base ~s(id = "t.p"\nname = "T"\nversion = "1"\nmin_herdr_version = "0.7.0"\nplatforms = ["linux"]\n)

  defp load_text(text, dir) do
    File.write!(Path.join(dir, "herdr-plugin.toml"), text)
    Manifest.load(dir)
  end

  test "vendored examples load" do
    for d <- ~w(agent-telegram-notify dev-layout-bootstrap github-link-preview rust-release-check) do
      assert {:ok, %{"plugin_id" => "examples." <> _}} = Manifest.load(Path.join(@examples, d))
    end

    {:ok, m} = Manifest.load(Path.join(@examples, "dev-layout-bootstrap"))
    assert m["plugin_id"] == "examples.dev-layout-bootstrap"

    assert [%{"id" => "setup", "qualified_id" => "examples.dev-layout-bootstrap.setup"}] =
             m["actions"]

    assert m["warnings"] == []

    {:ok, g} = Manifest.load(Path.join(@examples, "github-link-preview/herdr-plugin.toml"))
    assert [%{"id" => "github-issue-or-pr", "action" => "open"}] = g["link_handlers"]
    assert [%{"id" => "preview", "placement" => "split"}] = g["panes"]
    assert g["plugin_root"] == Path.join(@examples, "github-link-preview")

    {:ok, t} = Manifest.load(Path.join(@examples, "agent-telegram-notify"))
    assert "event pane.agent_status_changed is not emitted by herdr-live yet" in t["warnings"]

    {:ok, r} = Manifest.load(Path.join(@examples, "rust-release-check"))
    assert [%{"command" => ["cargo", "build", "--release"]}] = r["build"]
  end

  @tag :tmp_dir
  test "missing file and parse errors", %{tmp_dir: dir} do
    assert {:error, "plugin_manifest_not_found", _} = Manifest.load(Path.join(dir, "nope"))
    assert {:error, "plugin_manifest_parse_failed", _} = load_text("id = [", dir)
  end

  @failures [
    {"invalid_plugin_id",
     ~s(id = "a/b"\nname = "T"\nversion = "1"\nmin_herdr_version = "0.7.0"\n)},
    {"invalid_plugin_id", ~s(name = "T"\nversion = "1"\nmin_herdr_version = "0.7.0"\n)},
    {"invalid_plugin_name",
     ~s(id = "a"\nname = " "\nversion = "1"\nmin_herdr_version = "0.7.0"\n)},
    {"invalid_plugin_version", ~s(id = "a"\nname = "T"\nmin_herdr_version = "0.7.0"\n)},
    {"invalid_plugin_min_herdr_version", ~s(id = "a"\nname = "T"\nversion = "1"\n)},
    {"invalid_plugin_min_herdr_version",
     ~s(id = "a"\nname = "T"\nversion = "1"\nmin_herdr_version = "x"\n)},
    {"plugin_requires_newer_herdr",
     ~s(id = "a"\nname = "T"\nversion = "1"\nmin_herdr_version = "0.9.5"\n)},
    {"invalid_plugin_platform",
     ~s(id = "a"\nname = "T"\nversion = "1"\nmin_herdr_version = "0.7.0"\nplatforms = ["amiga"]\n)},
    {"invalid_plugin_action_id",
     @base <> ~s([[actions]]\nid = "a.b"\ntitle = "x"\ncommand = ["x"]\n)},
    {"invalid_plugin_action_title", @base <> ~s([[actions]]\nid = "a"\ncommand = ["x"]\n)},
    {"invalid_plugin_command", @base <> ~s([[actions]]\nid = "a"\ntitle = "x"\ncommand = []\n)},
    {"invalid_plugin_pane_id",
     @base <> ~s([[panes]]\nid = "a b"\ntitle = "x"\ncommand = ["x"]\n)},
    {"invalid_plugin_pane_size",
     @base <> ~s([[panes]]\nid = "a"\ntitle = "x"\nwidth = 40\ncommand = ["x"]\n)},
    {"duplicate_plugin_action_id",
     @base <> String.duplicate(~s([[actions]]\nid = "a"\ntitle = "x"\ncommand = ["x"]\n), 2)},
    {"duplicate_plugin_pane_id",
     @base <> String.duplicate(~s([[panes]]\nid = "a"\ntitle = "x"\ncommand = ["x"]\n), 2)},
    {"duplicate_plugin_link_handler_id",
     @base <>
       ~s([[actions]]\nid = "a"\ntitle = "x"\ncommand = ["x"]\n) <>
       String.duplicate(
         ~s([[link_handlers]]\nid = "h"\ntitle = "x"\npattern = "x"\naction = "a"\n),
         2
       )},
    {"invalid_plugin_link_handler_action",
     @base <> ~s([[link_handlers]]\nid = "h"\ntitle = "x"\npattern = "x"\naction = "nope"\n)},
    {"invalid_plugin_link_handler_pattern",
     @base <>
       ~s([[actions]]\nid = "a"\ntitle = "x"\ncommand = ["x"]\n[[link_handlers]]\nid = "h"\ntitle = "x"\npattern = "("\naction = "a"\n)}
  ]

  @tag :tmp_dir
  test "validation reasons", %{tmp_dir: dir} do
    for {reason, text} <- @failures do
      assert {:error, ^reason, msg} = load_text(text, dir), text
      assert is_binary(msg)
    end
  end

  @tag :tmp_dir
  test "plugin id length limit, popup size, event warnings", %{tmp_dir: dir} do
    long = String.duplicate("a", 121)
    assert {:error, "invalid_plugin_id", _} = load_text(String.replace(@base, "t.p", long), dir)
    assert {:ok, _} = load_text(String.replace(@base, "t.p", String.duplicate("a", 120)), dir)

    assert {:ok, %{"panes" => [%{"width" => "80%", "height" => 20}]}} =
             load_text(
               @base <>
                 ~s([[panes]]\nid = "a"\ntitle = "x"\nplacement = "popup"\nwidth = "80%"\nheight = 20\ncommand = ["x"]\n),
               dir
             )

    {:ok, m} =
      load_text(
        ~s(id = "a"\nname = "T"\nversion = "1"\nmin_herdr_version = "0.9.4"\n) <>
          ~s([[events]]\non = "bogus.event"\ncommand = ["x"]\n[[events]]\non = "tab.moved"\ncommand = ["x"]\n[[events]]\non = "pane.created"\ncommand = ["x"]\n),
        dir
      )

    assert "unknown event 'bogus.event'" in m["warnings"]
    assert "event tab.moved is not emitted by herdr-live yet" in m["warnings"]
    assert "manifest does not declare platforms; platform support unknown" in m["warnings"]
    refute Enum.any?(m["warnings"], &(&1 =~ "pane.created"))
  end

  test "platform_ok?" do
    me = if match?({:unix, :darwin}, :os.type()), do: "macos", else: "linux"
    assert Manifest.platform_ok?(nil, nil)
    assert Manifest.platform_ok?(nil, [me])
    refute Manifest.platform_ok?(nil, ["windows"])
    assert Manifest.platform_ok?([me], ["windows"])
    refute Manifest.platform_ok?(["windows"], [me])
    assert Manifest.compat_version() == "0.9.4"
  end
end
