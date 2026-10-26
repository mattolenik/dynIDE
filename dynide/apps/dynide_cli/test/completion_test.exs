defmodule DynideCli.CompletionTest do
  use ExUnit.Case, async: true

  alias DynideCli.{Argv, Completion}

  for shell <- [:bash, :zsh, :fish] do
    test "#{shell} script has every first word and pane split" do
      {:print, script} = Argv.parse(["completion", "#{unquote(shell)}"], %{})
      assert script == Completion.script(unquote(shell), Argv.commands())

      for w <- Argv.verbs() ++ ~w(help kernel-restart status completion split),
          do: assert(script =~ w)
    end
  end

  test "fish offers second words only while none is present" do
    script = Completion.script(:fish, Argv.commands())

    assert script =~
             "-n '__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish'"
  end

  test "--default-config with extra args is its own usage" do
    assert {:usage, msg} = Argv.parse(["--default-config", "extra"], %{})
    assert msg =~ "usage: dynide --default-config\n"
  end

  test "unknown shell is usage; --default-config prints the file" do
    assert {:usage, _} = Argv.parse(["completion", "csh"], %{})
    assert {:usage, _} = Argv.parse(["completion"], %{})
    assert {:print, "# dynIDE default config" <> _} = Argv.parse(["--default-config"], %{})
  end
end
