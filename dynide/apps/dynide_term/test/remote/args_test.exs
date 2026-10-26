defmodule DynideTerm.Remote.ArgsTest do
  use ExUnit.Case, async: true

  alias DynideTerm.Remote.Args

  @env %{"HOME" => "/h"}
  @sock "/h/.local/state/herdr-live/client.sock"
  @token "/h/.local/state/herdr-live/client.token"

  test "attach forms" do
    assert {:ok, o} = Args.parse(["attach"], @env)
    assert o[:transport] == {:unix, @sock, @token}
    assert o[:session] == nil and o[:target] == :session

    assert {:ok, o} = Args.parse(["attach", "box"], @env)
    assert o[:transport] == {:ssh, "box", nil} and o[:session] == nil

    assert {:ok, o} = Args.parse(["attach", "box", "work"], @env)
    assert o[:transport] == {:ssh, "box", "work"} and o[:session] == "work"
  end

  test "the client socket follows HERDR_LIVE_CLIENT_SOCK" do
    env = Map.put(@env, "HERDR_LIVE_CLIENT_SOCK", "/run/x/c.sock")
    assert {:ok, o} = Args.parse(["attach"], env)
    assert o[:transport] == {:unix, "/run/x/c.sock", "/run/x/client.token"}
  end

  test "terminal verbs" do
    assert {:ok, o} = Args.parse(["terminal", "observe", "p3"], @env)
    assert o[:target] == {:pane, 3, :observe}
    assert o[:transport] == {:unix, @sock, @token}

    assert {:ok, o} = Args.parse(["terminal", "attach", "p12", "--host", "box"], @env)
    assert o[:target] == {:pane, 12, :control}
    assert o[:transport] == {:ssh, "box", nil}

    assert {:ok, o} = Args.parse(["terminal", "attach", "--host", "box", "p12"], @env)
    assert o[:target] == {:pane, 12, :control}
  end

  test "usage errors" do
    for argv <- [
          [],
          ["nope"],
          ["attach", "a", "b", "c"],
          ["attach", "--host", "x"],
          ["terminal"],
          ["terminal", "attach"],
          ["terminal", "attach", "x"],
          ["terminal", "attach", "p0"],
          ["terminal", "attach", "p1", "p2"],
          ["terminal", "kill", "p1"],
          ["terminal", "attach", "p1", "--bogus"],
          ["terminal", "attach", "p1", "--host"]
        ] do
      assert {:usage, text} = Args.parse(argv, @env), inspect(argv)
      assert text =~ "herdr-live attach [<host>] [<session>]"
    end
  end

  test "usage lines" do
    assert "attach [<host>] [<session>]" in Args.usage_lines()
    assert Enum.all?(Args.usage_lines(), &(not String.starts_with?(&1, "herdr-live")))
  end

  test "ssh command per R13" do
    opts = ~w(-T -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
    assert Args.ssh_command("box", %{}) == {"ssh", opts ++ ~w(box herdr-live attach-relay)}

    env = %{"HERDR_LIVE_SSH" => "ssh -p 2222", "HERDR_LIVE_REMOTE_BIN" => "/opt/hl"}

    assert Args.ssh_command("box", env) ==
             {"ssh", ~w(-p 2222) ++ opts ++ ~w(box /opt/hl attach-relay)}

    assert Args.ssh_command("box", %{"HERDR_LIVE_SSH" => ""}) |> elem(0) == "ssh"
  end
end
