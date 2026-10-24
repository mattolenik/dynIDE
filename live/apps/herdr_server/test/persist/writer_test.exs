defmodule HerdrServer.Persist.WriterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.{Mirror, Pane.Rows}
  alias HerdrServer.Persist.{Disk, Writer}

  @moduletag :tmp_dir
  @moduletag :capture_log
  @size %{cols: 80, rows: 24, cell_px: nil}

  setup %{tmp_dir: tmp} do
    Store.reset()
    on_exit(&Store.reset/0)
    on_exit(fn -> :persistent_term.erase(Protocol.handoff_key()) end)
    :ok = Store.event({:resize, @size}, nil)
    {:ok, cfg: %{dir: Path.join(tmp, "state"), name: "default"}}
  end

  defp start(cfg, opts \\ []) do
    opts = Keyword.merge([enabled: true, dir: cfg.dir, poll_ms: 20, scrollback_ms: 50], opts)
    start_supervised!({Writer, opts})
  end

  # logs of the writer's final write on stop stay inside the capture too
  defp quiet(fun) do
    capture_log(fn ->
      fun.()
      stop_supervised(Writer)
    end)
  end

  defp split, do: :ok = Store.run({Actions, :split, [:horizontal]}, @size)

  defp pane_count(cfg) do
    case Disk.read(cfg) do
      {:ok, snap, _} -> map_size(snap.panes)
      _ -> 0
    end
  end

  defp wait_until(fun, ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  defp pty(id) do
    {:ok, res} = Fake.Keeper.lookup(Rows.kernel_id(id))
    res.pty
  end

  test "not enabled: start_link ignores" do
    assert Writer.start_link(enabled: false) == :ignore
  end

  test "a split appears on disk", %{cfg: cfg} do
    quiet(fn ->
      start(cfg)
      wait_until(fn -> pane_count(cfg) == 1 end)
      split()
      wait_until(fn -> pane_count(cfg) == 2 end)
    end)
  end

  test "no write when nothing changed", %{cfg: cfg} do
    quiet(fn ->
      start(cfg)
      wait_until(fn -> pane_count(cfg) == 1 end)
      # facts may settle over a tick or two
      Process.sleep(60)
      %{writes: w} = Writer.stats()
      Process.sleep(200)
      assert %{writes: ^w, skipped: s} = Writer.stats()
      assert s > 0
    end)
  end

  test "a cwd change alone is written", %{cfg: cfg} do
    quiet(fn ->
      start(cfg)
      wait_until(fn -> pane_count(cfg) == 1 end)
      [id] = Map.keys(Mirror.app().session.panes)
      Fake.Pty.set_cwd(pty(id), "/moved/here")

      wait_until(fn ->
        match?({:ok, %{panes: %{^id => %{cwd: "/moved/here"}}}, _}, Disk.read(cfg))
      end)
    end)
  end

  test "during a handoff nothing is written, not even on stop", %{cfg: cfg} do
    :persistent_term.put(Protocol.handoff_key(), :released)

    quiet(fn ->
      pid = start(cfg)
      split()
      Process.sleep(200)
      assert Disk.read(cfg) == :none
      assert %{writes: 0} = Writer.stats()
      :ok = stop_supervised(Writer)
      refute Process.alive?(pid)
      assert Disk.read(cfg) == :none
    end)
  end

  test "after an aborted handoff the unchanged app is written again", %{cfg: cfg} do
    quiet(fn ->
      start(cfg)
      wait_until(fn -> pane_count(cfg) == 1 end)
      # settle: no more writes for an unchanged app
      Process.sleep(60)
      %{writes: w, skipped: s} = Writer.stats()
      :persistent_term.put(Protocol.handoff_key(), :begin)
      wait_until(fn -> Writer.stats().skipped >= s + 2 end)
      assert %{writes: ^w} = Writer.stats()
      :persistent_term.put(Protocol.handoff_key(), :aborted)
      wait_until(fn -> Writer.stats().writes == w + 1 end)
    end)
  end

  test "the child spec gives terminate time to write" do
    assert %{shutdown: 10_000} = Writer.child_spec([])
  end

  test "a normal stop writes the latest app", %{cfg: cfg} do
    quiet(fn ->
      start(cfg, poll_ms: 60_000, scrollback_ms: 60_000)
      split()
      assert Disk.read(cfg) == :none
      :ok = stop_supervised(Writer)
      assert pane_count(cfg) == 2
    end)
  end

  test "flush writes now", %{cfg: cfg} do
    quiet(fn ->
      start(cfg, poll_ms: 60_000, scrollback_ms: 60_000)
      wait_until(fn -> Mirror.app() != nil end)
      assert Writer.flush() == :ok
      assert pane_count(cfg) == 1
      assert %{writes: 1, last_bytes: b, last_us: us} = Writer.stats()
      assert b > 0 and us >= 0
    end)
  end

  test "scrollback file appears after output", %{cfg: cfg} do
    quiet(fn ->
      start(cfg)
      wait_until(fn -> pane_count(cfg) == 1 end)
      [id] = Map.keys(Mirror.app().session.panes)
      Fake.Pty.output(pty(id), "marker\r\n")
      wait_until(fn -> (Disk.read_scrollback(cfg, id) || "") =~ "marker" end)
      assert %{scrollback_writes: n} = Writer.stats()
      assert n >= 1
    end)
  end

  @root System.cmd("id", ["-u"]) |> elem(0) |> String.trim() == "0"

  @tag skip: if(@root, do: "root writes into a mode-0500 dir")
  test "a read-only dir logs one persist_error and the writer lives", %{cfg: cfg} do
    File.mkdir_p!(cfg.dir)
    File.chmod!(cfg.dir, 0o500)
    on_exit(fn -> File.chmod(cfg.dir, 0o700) end)

    log =
      quiet(fn ->
        pid = start(cfg)
        wait_until(fn -> Mirror.app() != nil end)
        [id] = Map.keys(Mirror.app().session.panes)

        # five changes, each seen by at least two failed write attempts
        for n <- 1..5 do
          Fake.Pty.set_cwd(pty(id), "/change/#{n}")
          %{skipped: s} = Writer.stats()
          wait_until(fn -> Writer.stats().skipped >= s + 2 end)
        end

        assert Process.alive?(pid)
        assert %{writes: 0} = Writer.stats()
      end)

    assert length(Regex.scan(~r/herdr-event persist_error /, log)) == 1
    assert log =~ ~r/persist_error ts=\d+ op=write reason=/
  end

  test "a Disk call that raises skips the tick and the writer lives", %{cfg: cfg} do
    # a dir that is not a binary: every Disk call (sweep, write, scrollback, prune) raises
    log =
      quiet(fn ->
        pid = start(cfg, dir: 123)
        wait_until(fn -> Mirror.app() != nil end)
        [id] = Map.keys(Mirror.app().session.panes)
        Fake.Pty.output(pty(id), "marker\r\n")
        %{skipped: s} = Writer.stats()
        # several layout ticks and at least two scrollback rounds
        wait_until(fn -> Writer.stats().skipped >= s + 5 end)
        Process.sleep(120)
        assert Process.alive?(pid)
        assert %{writes: 0, scrollback_writes: 0} = Writer.stats()
      end)

    assert length(Regex.scan(~r/herdr-event persist_error /, log)) == 1
    assert log =~ ~r/persist_error ts=\d+ op=sweep reason=.*FunctionClauseError/
  end
end
