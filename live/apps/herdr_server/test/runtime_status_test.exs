defmodule HerdrServer.RuntimeStatusTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Scene.Node
  alias HerdrServer.RuntimeStatus

  defp run(events, now \\ 0) do
    Enum.reduce(events, RuntimeStatus.new(), &RuntimeStatus.apply(&2, &1, now))
  end

  defp texts(t, free \\ 80), do: t |> RuntimeStatus.nodes(free) |> Enum.map(& &1.text)

  defp reload_text(t),
    do: t |> RuntimeStatus.nodes(80) |> Enum.find(&(&1.id == :reload)) |> Map.get(:text)

  defp guard_raise(msg), do: {:raise, RuntimeError.exception(msg), []}

  test "new/0 is empty and renders nothing" do
    assert RuntimeStatus.new() == %{reload: nil, tests: nil, handoff: nil}
    assert RuntimeStatus.nodes(RuntimeStatus.new(), 80) == []
    assert RuntimeStatus.nodes(nil, 80) == []
  end

  test "loaded, rolled back, loaded: the newest batch wins" do
    t1 = run([{:herdr_reload, {:loaded, 3, [A, B]}}])
    assert reload_text(t1) == "r3 2m"
    assert %{state: :loaded, batch: 3, fanout: 2, modules: [A, B], reason: nil} = t1.reload

    t2 =
      RuntimeStatus.apply(
        t1,
        {:herdr_reload,
         {:rolled_back, 3, [A, B], guard_raise("boom " <> String.duplicate("x", 50))}}
      )

    text = reload_text(t2)
    assert "r3 rolled back: " <> reason = text
    assert reason == String.slice("** (RuntimeError) boom xxxxxxx", 0, 24)
    assert String.length(reason) == 24
    assert t2.reload.state == :rolled_back

    t3 = RuntimeStatus.apply(t2, {:herdr_reload, {:loaded, 4, [A]}})
    assert reload_text(t3) == "r4 1m"
  end

  test "manual rollback and load-error rollbacks use the shared summary" do
    t = run([{:herdr_reload, {:rolled_back, 2, [A], :manual}}])
    assert reload_text(t) == "r2 rolled back: manual"
    t = run([{:herdr_reload, {:rolled_back, 2, [A], {:manual, [{A, :badfile}]}}}])
    assert reload_text(t) == "r2 rolled back: manual (load errors)"
  end

  test "synced, then loaded: the newer event wins" do
    t = run([{:herdr_reload, {:synced, [A, B, C, D]}}])
    assert reload_text(t) == "synced 4m, no rollback"
    assert %{state: :synced, batch: nil, fanout: 4, modules: [A, B, C, D]} = t.reload
    assert [%Node{token: :warning}] = RuntimeStatus.nodes(t, 80)

    t = RuntimeStatus.apply(t, {:herdr_reload, {:loaded, 5, [A, B]}})
    assert reload_text(t) == "r5 2m"
    # an empty sync changes nothing
    assert RuntimeStatus.apply(t, {:herdr_reload, {:synced, []}}) == t
  end

  test "the other reload states, with their tokens" do
    diag = %{file: "lib/foo.ex", position: {1, 2}, message: "undefined x"}

    for {ev, text, token} <- [
          {{:compile_error, [diag]}, "r! compile", :error},
          {{:loaded, 1, [A]}, "r1 1m", :muted},
          {{:rejected, A, [:x]}, "r rejected", :warning},
          {{:purge_blocked, A, [self()]}, "r blocked", :warning}
        ] do
      [n] = RuntimeStatus.nodes(run([{:herdr_reload, ev}]), 80)
      assert %Node{role: :text, id: :reload, text: ^text, token: ^token} = n
      assert n.props == run([{:herdr_reload, ev}]).reload
    end
  end

  test "test results" do
    for {ev, text, token} <- [
          {{:tests, :running, %{files: 2}}, "tests...", :muted},
          {{:tests, :passed, %{files: 2, failures: 0, ms: 900}}, "tests ok", :muted},
          {{:tests, :failed, %{files: 2, failures: 3, ms: 900}}, "tests 3 failed", :error},
          {{:tests, :error, %{files: 0, failures: 0, ms: 10}}, "tests error", :error}
        ] do
      t = run([{:herdr_reload, ev}])

      assert [%Node{id: :tests, text: ^text, token: ^token, props: props}] =
               RuntimeStatus.nodes(t, 80)

      assert props == t.tests
    end

    t = run([{:herdr_reload, {:tests, :running, %{files: 2}}}])
    assert t.tests == %{result: :running, files: 2, failures: 0, ms: nil}
  end

  test "handoff phases, and expiry after 30 s" do
    t = run([{:handoff, %{phase: :begin, gen: 1, panes: [1, 2]}}], 1_000)
    assert t.handoff == %{phase: :begin, kind: nil, gen: 1, panes: 2, at: 1_000}
    assert texts(t) == ["handoff..."]

    t =
      RuntimeStatus.apply(
        t,
        {:handoff, %{phase: :adopted, gen: 2, panes: [1], kind: :graceful}},
        2_000
      )

    assert [%Node{id: :handoff, text: "handoff graceful g2", token: :accent}] =
             RuntimeStatus.nodes(t, 80)

    assert RuntimeStatus.expire(t, 31_999).handoff != nil
    assert RuntimeStatus.expire(t, 32_000).handoff == nil
    # reload never expires
    t = RuntimeStatus.apply(t, {:herdr_reload, {:loaded, 1, [A]}}, 0)
    assert RuntimeStatus.expire(t, 10_000_000).reload != nil
  end

  test "nodes drop handoff first, then tests, then reload, to fit the free columns" do
    t =
      run([
        {:herdr_reload, {:loaded, 3, [A, B]}},
        {:herdr_reload, {:tests, :passed, %{files: 1, failures: 0, ms: 5}}},
        {:handoff, %{phase: :begin, gen: 1, panes: []}}
      ])

    # "r3 2m" 6, "tests ok" 9, "handoff..." 11 (text + 1 gap each)
    assert texts(t, 80) == ["r3 2m", "tests ok", "handoff..."]
    assert texts(t, 26) == ["r3 2m", "tests ok", "handoff..."]
    assert texts(t, 25) == ["r3 2m", "tests ok"]
    assert texts(t, 15) == ["r3 2m", "tests ok"]
    assert texts(t, 10) == ["r3 2m"]
    assert texts(t, 6) == ["r3 2m"]
    assert texts(t, 5) == []
    assert texts(t, -3) == []
    assert Enum.map(RuntimeStatus.nodes(t, 80), & &1.id) == [:reload, :tests, :handoff]
  end
end
