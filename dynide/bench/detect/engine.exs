# Detection engine bench. Run: cd dynide && mix run bench/detect/engine.exs
# Bundled claude, codex and opencode manifests against synthetic 120x40 screens.
alias HerdrServer.Detect.{Engine, Manifests}

defmodule EngineBench do
  @cols 120
  @rows 40

  # Pads to 40 rows of 120 columns, content at the bottom, like a live pane.
  def screen(lines) do
    filler = List.duplicate("", @rows - length(lines))
    (filler ++ lines) |> Enum.map_join("\n", &String.pad_trailing(&1, @cols)) |> Kernel.<>("\n")
  end

  def history, do: for(i <- 1..20, do: "  line #{i}: some earlier output from the agent session")

  def screens do
    rule = String.duplicate("─", @cols)

    %{
      "prompt box idle" =>
        screen(history() ++ ["", rule, "> ", rule, "  ? for shortcuts", "› ", ""]),
      "spinner working" =>
        screen(history() ++ ["• Working (12s • esc to interrupt)", "✻ Thinking… (12s · esc to interrupt)", "", rule, "> ", rule]),
      "permission dialog blocked" =>
        screen(history() ++ [rule, " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)", "", "Allow once  Allow always  Reject", rule]),
      "plain shell" => screen(for(i <- 1..38, do: "drwxr-xr-x  5 matt staff  160 Oct 24 12:#{i} dir#{i}") ++ ["$ "])
    }
  end

  def run(entry, input, n) do
    Enum.each(1..div(n, 10), fn _ -> Engine.detect(entry, input) end)

    times =
      for _ <- 1..n do
        t0 = System.monotonic_time(:nanosecond)
        Engine.detect(entry, input)
        System.monotonic_time(:nanosecond) - t0
      end

    sorted = Enum.sort(times)
    at = fn q -> Enum.at(sorted, min(round(q * n), n - 1)) / 1000 end
    {at.(0.5), at.(0.95), List.last(sorted) / 1000}
  end
end

n = 2000
{load, 0} = System.cmd("uptime", [])
IO.puts("load: #{String.trim(load)}")

for agent <- ~w(claude codex opencode), {name, screen} <- Enum.sort(EngineBench.screens()) do
  entry = Manifests.get(agent) || raise "no bundled #{agent} manifest"
  input = %{screen: screen, osc_title: "", osc_progress: ""}
  d = Engine.detect(entry, input)
  {p50, p95, max} = EngineBench.run(entry, input, n)

  IO.puts(
    :io_lib.format("~-9s ~-26s ~-8s p50 ~8.1f us  p95 ~8.1f us  max ~8.1f us", [
      agent,
      name,
      Atom.to_string(d.state),
      p50,
      p95,
      max
    ])
  )
end

{load, 0} = System.cmd("uptime", [])
IO.puts("load: #{String.trim(load)}")
