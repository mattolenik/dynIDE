defmodule HerdrIntegration.DefaultConfigTest do
  @moduledoc "`herdr-live --default-config` loads clean and states the real defaults."
  use ExUnit.Case, async: true

  alias HerdrServer.App.{Keybinds, Ui}
  alias HerdrServer.Config

  @path Application.app_dir(:herdr_cli, "priv/default_config.toml")

  # {table, key path, Ui path}; mirrors Config's @fields (delay is seconds there)
  @fields [
    {:ui, ["sidebar_width"], [:sidebar, :width]},
    {:ui, ["sidebar_min_width"], [:sidebar, :min]},
    {:ui, ["sidebar_max_width"], [:sidebar, :max]},
    {:ui, ["confirm_close"], [:confirm_close]},
    {:ui, ["status_indicators"], [:indicators]},
    {:ui, ["prompt_new_tab_name"], [:prompt_new_tab_name]},
    {:ui, ["sound", "enabled"], [:sound, :enabled]},
    {:ui, ["toast", "delivery"], [:toast, :delivery]},
    {:ui, ["toast", "delay_seconds"], [:toast, :delay_ms]},
    {:theme, ["name"], [:theme, :name]},
    {:theme, ["auto_switch"], [:theme, :auto_switch]},
    {:theme, ["light_name"], [:theme, :light]},
    {:theme, ["dark_name"], [:theme, :dark]}
  ]

  test "loads with no diagnostics and every value equals the default" do
    cfg = Config.load(@path)
    assert cfg.diagnostics == [] and not cfg.failed

    ui = %Ui{}

    for {table, keys, at} <- @fields do
      raw = get_in(Map.fetch!(cfg, table), keys)
      want = get_in(ui, Enum.map(at, &Access.key/1))
      got = if at == [:toast, :delay_ms], do: raw * 1000, else: raw
      assert to_string(got) == to_string(want), "#{table}.#{Enum.join(keys, ".")}"
    end
  end

  test "the commented [keys] are the keybind defaults" do
    text = File.read!(@path)

    for {action, specs} <- Keybinds.to_config(Keybinds.default()) do
      assert text =~ "# #{action} = #{inspect(specs)}", action
    end
  end
end
