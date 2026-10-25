defmodule HerdrCli.CompletionTest do
  use ExUnit.Case, async: true

  alias HerdrCli.{Argv, Completion}

  for shell <- [:bash, :zsh, :fish] do
    test "#{shell} script has every first word and pane split" do
      {:print, script} = Argv.parse(["completion", "#{unquote(shell)}"], %{})
      assert script == Completion.script(unquote(shell), Argv.commands())

      for w <- Argv.verbs() ++ ~w(help kernel-restart status completion split),
          do: assert(script =~ w)
    end
  end

  test "unknown shell is usage; --default-config prints the file" do
    assert {:usage, _} = Argv.parse(["completion", "csh"], %{})
    assert {:usage, _} = Argv.parse(["completion"], %{})
    assert {:print, "# herdr-live default config" <> _} = Argv.parse(["--default-config"], %{})
  end
end
