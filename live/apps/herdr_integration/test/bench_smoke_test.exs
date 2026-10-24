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
    json = Mix.Project.build_path() |> Path.dirname() |> Path.join("bench/m3.json")
    report = json |> File.read!() |> JSON.decode!()

    for key <- @keys do
      assert is_number(report[key]), "#{key} = #{inspect(report[key])}"
    end
  end
end
