defmodule HerdrIntegration.BenchSmokeTest do
  @moduledoc "Smoke for `mix herdr.bench --quick`: the JSON report has every metric as a number."
  use ExUnit.Case, async: false

  alias Mix.Tasks.Herdr.Bench

  @moduletag :bench
  @moduletag timeout: 300_000

  @keys ~w(keystroke_fast_p95_us keystroke_slow_p95_us frame_1_mean_us frame_15_mean_us
           frame_ratio stall_probe_max_ms long_schedule_count typing_during_flood_p95_us)

  test "quick run writes every metric" do
    ExUnit.CaptureIO.capture_io(fn -> Bench.run(["--quick"]) end)
    json = Mix.Project.build_path() |> Path.dirname() |> Path.join("bench/m3-quick.json")
    report = json |> File.read!() |> JSON.decode!()

    for key <- @keys do
      assert is_number(report[key]), "#{key} = #{inspect(report[key])}"
    end
  end

  test "quick run at 120x40 reports frame cost and the second-client row" do
    ExUnit.CaptureIO.capture_io(fn -> Bench.run(["--quick", "--size", "120x40"]) end)
    json = Mix.Project.build_path() |> Path.dirname() |> Path.join("bench/m3-120x40-quick.json")
    report = json |> File.read!() |> JSON.decode!()

    for path <- [~w(frame_1 repaint p95), ~w(frame_15 repaint p95), ~w(second_client p95)] do
      assert is_number(get_in(report, path)),
             "#{Enum.join(path, ".")} = #{inspect(get_in(report, path))}"
    end

    assert report["second_client"]["n"] > 0
  end

  test "--size below 60x20 is refused" do
    assert_raise Mix.Error, ~r/too small/, fn -> Bench.run(["--quick", "--size", "20x5"]) end
  end
end
