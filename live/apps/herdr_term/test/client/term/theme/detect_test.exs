defmodule HerdrTerm.Client.Term.Theme.DetectTest do
  use ExUnit.Case, async: true

  alias HerdrTerm.Client.Term.Theme.Detect

  test "osc 11 bodies" do
    assert Detect.from_osc11("rgb:ffff/ffff/ffff") == :light
    assert Detect.from_osc11("rgb:1e1e/1e1e/2e2e") == :dark
    assert Detect.from_osc11("rgb:ff/ff/ff") == :light
    assert Detect.from_osc11("rgb:00/00/00") == :dark
    assert Detect.from_osc11("rgb:f/f/f") == :light
    assert Detect.from_osc11("garbage") == nil
    assert Detect.from_osc11("rgb:zz/00/00") == nil
  end

  test "luminance threshold is 128000 on 8-bit channels" do
    assert Detect.from_rgb({128, 128, 128}) == :light
    assert Detect.from_rgb({127, 127, 127}) == :dark
    assert Detect.from_rgb(nil) == nil
  end

  test "colorfgbg" do
    assert Detect.from_colorfgbg("15;0") == :dark
    assert Detect.from_colorfgbg("0;15") == :light
    assert Detect.from_colorfgbg("0;7") == :light
    assert Detect.from_colorfgbg("0;default;15") == :light
    assert Detect.from_colorfgbg("x") == nil
    assert Detect.from_colorfgbg(nil) == nil
  end

  test "dsr" do
    assert Detect.from_dsr(1) == :dark
    assert Detect.from_dsr(2) == :light
    assert Detect.from_dsr(3) == nil
  end

  test "precedence: scheme > colors.bg > colorfgbg > dark" do
    light_bg = %{colors: %{bg: {255, 255, 255}}, scheme: nil}
    assert Detect.appearance(%{light_bg | scheme: :dark}, "0;15") == :dark
    assert Detect.appearance(light_bg, "15;0") == :light
    assert Detect.appearance(%{colors: nil, scheme: nil}, "0;15") == :light
    assert Detect.appearance(nil, nil) == :dark
  end
end
