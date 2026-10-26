defmodule DynideServer.Pane.OscTest do
  use ExUnit.Case, async: true

  alias DynideServer.Pane.Osc

  describe "title/1" do
    test "strips C0, C1 and DEL" do
      assert Osc.title("a\eb") == "ab"
      assert Osc.title("x\x07y\x7fz\u0085w\u009b") == "xyzw"
    end

    test "keeps at most 256 chars" do
      assert Osc.title(String.duplicate("é", 300)) == String.duplicate("é", 256)
    end

    test "empty or all-control is nil" do
      assert Osc.title("") == nil
      assert Osc.title("\e\x07") == nil
    end

    test "invalid utf-8 is replaced, not raised" do
      assert Osc.title(<<"a", 0xFF, "b">>) == "a�b"
    end
  end

  describe "stripped_title/1" do
    test "drops one leading activity glyph followed by whitespace or end" do
      assert Osc.stripped_title("⠋ claude") == "claude"
      assert Osc.stripped_title("  ✳   task  ") == "task"
      assert Osc.stripped_title("◒ task") == "task"
      assert Osc.stripped_title("· x") == "x"
    end

    test "keeps a glyph glued to text, and only one glyph" do
      assert Osc.stripped_title("⠋claude") == "⠋claude"
      assert Osc.stripped_title("⠋ ⠙ a") == "⠙ a"
    end

    test "nil, blank and glyph-only are nil" do
      assert Osc.stripped_title(nil) == nil
      assert Osc.stripped_title("   ") == nil
      assert Osc.stripped_title("⠋") == nil
    end
  end

  describe "cwd/1" do
    test "file uri with localhost, empty or own host" do
      assert Osc.cwd("file://localhost/tmp/a%20b") == {:ok, "/tmp/a b"}
      assert Osc.cwd("file:///tmp") == {:ok, "/tmp"}
      assert Osc.cwd("file://LOCALHOST/tmp") == {:ok, "/tmp"}
      {:ok, host} = :inet.gethostname()
      assert Osc.cwd("file://#{host}/var") == {:ok, "/var"}
    end

    test "other hosts and broken uris are errors" do
      assert Osc.cwd("file://otherhost/tmp") == :error
      assert Osc.cwd("file://localhost/a%zz") == :error
      assert Osc.cwd("file://localhost/a%ff") == :error
      assert Osc.cwd("file://localhost/a%+1") == :error
      assert Osc.cwd("file://localhost") == :error
    end

    test "bare or quoted absolute path" do
      assert Osc.cwd("/usr/local") == {:ok, "/usr/local"}
      assert Osc.cwd(" \"/a b\" ") == {:ok, "/a b"}
      assert Osc.cwd("relative/dir") == :error
      assert Osc.cwd("") == :error
    end
  end

  describe "event/2" do
    test "osc 9: 9;<path> is cwd, anything else progress" do
      assert Osc.event(9, "9;/tmp") == {:cwd, "/tmp"}
      assert Osc.event(9, "9;\"/tmp\"") == {:cwd, "/tmp"}
      assert Osc.event(9, "4;3;") == {:progress, "4;3;"}
      assert Osc.event(9, "4;1;5\e") == {:progress, "4;1;5"}
      assert Osc.event(9, "") == :ignore
      assert Osc.event(9, "9;nope") == :ignore
    end

    test "osc 1337 CurrentDir" do
      assert Osc.event(1337, "CurrentDir=/tmp/x") == {:cwd, "/tmp/x"}
      assert Osc.event(1337, "SetMark") == :ignore
    end

    test "osc 52 clipboard" do
      assert Osc.event(52, "c;" <> Base.encode64("hi")) == {:clipboard, "hi"}
      assert Osc.event(52, ";" <> Base.encode64("hi")) == {:clipboard, "hi"}
      assert Osc.event(52, "c;aGk") == {:clipboard, "hi"}
      assert Osc.event(52, "p;" <> Base.encode64("hi")) == :ignore
      assert Osc.event(52, "c;?") == :ignore
      assert Osc.event(52, "c;") == :ignore
      assert Osc.event(52, "c;!!!") == :ignore
      assert Osc.event(52, "c") == :ignore
    end

    test "osc 52 size cap" do
      ok = :binary.copy("a", 196_608)
      assert Osc.event(52, "c;" <> Base.encode64(ok)) == {:clipboard, ok}
      big = :binary.copy("a", 200 * 1024)
      assert Osc.event(52, "c;" <> Base.encode64(big)) == :ignore
    end

    test "truncated payloads and unknown codes are ignored" do
      assert Osc.event(52, {:truncated, "c;aGk"}) == :ignore
      assert Osc.event(9, {:truncated, "4;3;"}) == :ignore
      assert Osc.event(133, "A") == :ignore
    end
  end
end
