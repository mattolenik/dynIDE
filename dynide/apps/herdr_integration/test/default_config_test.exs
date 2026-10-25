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
      # atoms (enums) come from the file as strings; everything else must match by type
      got = if is_atom(want) and is_binary(got), do: String.to_atom(got), else: got
      assert got === want, "#{table}.#{Enum.join(keys, ".")}"
    end
  end

  test "the commented [keys] are exactly the keybind defaults" do
    [_, keys] = String.split(File.read!(@path), "\n[keys]\n")

    listed =
      for "# " <> line <- String.split(keys, "\n"),
          [name, val] = String.split(line, " = ", parts: 2) do
        {name, val |> Code.eval_string() |> elem(0)}
      end

    want = Keybinds.to_config(Keybinds.default()) |> Enum.map(fn {a, s} -> {to_string(a), s} end)
    assert MapSet.new(listed) == MapSet.new(want)
    assert length(listed) == length(want)
  end
end
