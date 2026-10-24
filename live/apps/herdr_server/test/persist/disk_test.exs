defmodule HerdrServer.Persist.DiskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias HerdrServer.Persist.{Disk, Schema}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    cfg = %{dir: Path.join(dir, "state"), name: "t"}
    {:ok, cfg: cfg, path: Disk.session_path(cfg)}
  end

  defp snapshot, do: %{v: 1, panes: %{1 => %{cwd: "/tmp", command: ["sh"], hidden: false}}}

  defp envelope(fields) do
    %{format: :herdr_live_session, v: Schema.version(), saved_at: 1, snapshot: snapshot()}
    |> Map.merge(fields)
    |> :erlang.term_to_binary()
  end

  defp aside(cfg),
    do:
      cfg.dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "session.t.etf."))
      |> Enum.sort()

  test "paths", %{cfg: cfg} do
    assert Disk.session_path(cfg) == Path.join(cfg.dir, "session.t.etf")
    assert Disk.scrollback_dir(cfg) == Path.join(cfg.dir, "session.t.scrollback")
  end

  test "write then read round trips, 0600, no temp file left", %{cfg: cfg, path: path} do
    assert Disk.read(cfg) == :none
    assert Disk.write(cfg, snapshot()) == :ok
    assert {:ok, snap, saved_at} = Disk.read(cfg)
    assert snap == snapshot()
    assert saved_at > 0
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(cfg.dir).mode |> Bitwise.band(0o777) == 0o700
    assert File.ls!(cfg.dir) == ["session.t.etf"]

    assert {:ok, %{format: :herdr_live_session, v: 1, snapshot: _}} =
             {:ok, path |> File.read!() |> :erlang.binary_to_term()}
  end

  test "a snapshot holding a fun is refused and nothing is written", %{cfg: cfg} do
    assert Disk.write(cfg, %{v: 1, f: fn -> :ok end}) == {:error, :not_plain}
    refute File.exists?(Disk.session_path(cfg))
  end

  for {label, bytes, suffix} <- [
        {"truncated", :truncated, ~r/^session\.t\.etf\.bad-\d+$/},
        {"random bytes", <<1, 2, 3, 4, 5, 6>>, ~r/^session\.t\.etf\.bad-\d+$/},
        {"wrong format", :wrong_format, ~r/^session\.t\.etf\.bad-\d+$/},
        {"newer version", :newer, ~r/^session\.t\.etf\.v99-\d+$/}
      ] do
    @bytes bytes
    @suffix suffix
    test "#{label} is moved aside, then read is :none", %{cfg: cfg, path: path} do
      bin =
        case @bytes do
          :truncated -> binary_part(envelope(%{}), 0, 10)
          :wrong_format -> envelope(%{format: :something_else})
          :newer -> envelope(%{v: 99})
          b -> b
        end

      File.mkdir_p!(cfg.dir)
      File.write!(path, bin)
      log = capture_log(fn -> assert {:error, _} = Disk.read(cfg) end)
      assert log =~ "persist_error"
      assert [moved] = aside(cfg)
      assert moved =~ @suffix
      assert Disk.read(cfg) == :none
    end
  end

  test "only the 5 newest moved-aside files are kept", %{cfg: cfg, path: path} do
    File.mkdir_p!(cfg.dir)

    names =
      for _ <- 1..6 do
        File.write!(path, "junk")
        capture_log(fn -> assert {:error, _} = Disk.read(cfg) end)
        aside(cfg)
      end

    [first | _] = hd(names)
    final = List.last(names)
    assert length(final) == 5
    refute first in final
  end

  test "scrollback round trip, prune and corrupt file", %{cfg: cfg} do
    assert Disk.read_scrollback(cfg, 1) == nil
    assert Disk.write_scrollback(cfg, 1, "one\r\n", 80) == :ok
    assert Disk.write_scrollback(cfg, 2, "two", 80) == :ok
    assert Disk.write_scrollback(cfg, 3, "three", 80) == :ok
    assert Disk.read_scrollback(cfg, 1) == "one\r\n"
    sdir = Disk.scrollback_dir(cfg)
    assert File.stat!(Path.join(sdir, "1.etf")).mode |> Bitwise.band(0o777) == 0o600

    assert Disk.prune_scrollback(cfg, [1, 3]) == :ok
    assert File.ls!(sdir) |> Enum.sort() == ["1.etf", "3.etf"]
    assert Disk.read_scrollback(cfg, 2) == nil

    File.write!(Path.join(sdir, "3.etf"), "garbage")
    assert Disk.read_scrollback(cfg, 3) == nil
    refute File.exists?(Path.join(sdir, "3.etf"))

    File.write!(Path.join(sdir, "1.etf"), :erlang.term_to_binary(%{format: :other}))
    assert Disk.read_scrollback(cfg, 1) == nil
    refute File.exists?(Path.join(sdir, "1.etf"))
  end

  test "prune of a missing scrollback dir is :ok", %{cfg: cfg} do
    assert Disk.prune_scrollback(cfg, []) == :ok
  end

  describe "resolve_name/1" do
    test "valid names pass, nil and empty give default" do
      assert Disk.resolve_name("work_1.a-b") == "work_1.a-b"
      assert Disk.resolve_name(nil) == "default"
      assert Disk.resolve_name("") == "default"
    end

    test "invalid names give default with a warning" do
      for bad <- ["../x", "a/b", String.duplicate("a", 65), "sp ace"] do
        log = capture_log(fn -> assert Disk.resolve_name(bad) == "default" end)
        assert log =~ "HERDR_LIVE_SESSION"
      end
    end
  end

  describe "resolve_dir/1" do
    test "HERDR_LIVE_STATE_DIR wins, then XDG_STATE_HOME, then HOME" do
      assert Disk.resolve_dir(%{"HERDR_LIVE_STATE_DIR" => "/s", "XDG_STATE_HOME" => "/x"}) == "/s"

      assert Disk.resolve_dir(%{"XDG_STATE_HOME" => "/x", "HOME" => "/h"}) ==
               "/x/herdr-live"

      assert Disk.resolve_dir(%{
               "HERDR_LIVE_STATE_DIR" => "",
               "XDG_STATE_HOME" => "",
               "HOME" => "/h"
             }) ==
               "/h/.local/state/herdr-live"
    end
  end

  test "config/0 merges defaults and resolves dir and name" do
    cfg = Disk.config()
    assert cfg.enabled == false
    assert cfg.poll_ms == 1000
    assert cfg.scrollback_ms == 60_000
    assert cfg.scrollback_rows == 1000
    assert is_binary(cfg.dir) and cfg.dir != ""
    assert cfg.name =~ ~r/^[A-Za-z0-9_.-]{1,64}$/
  end
end
