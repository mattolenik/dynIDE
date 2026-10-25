defmodule HerdrCli.Completion do
  @moduledoc "Shell completion scripts for `herdr-live`, built from the `Argv` command rows."

  @extra [~w(help), ~w(kernel-restart), ~w(status)] ++
           for(s <- ~w(bash zsh fish), do: ["completion", s])

  @doc "The script for `shell`; completes the first word and, after it, the second."
  @spec script(:bash | :zsh | :fish, [map()]) :: String.t()
  def script(shell, commands) do
    words = Enum.map(commands, & &1.words) ++ @extra
    firsts = words |> Enum.map(&hd/1) |> Enum.uniq()
    seconds = Enum.group_by(for([f, s] <- words, do: {f, s}), &elem(&1, 0), &elem(&1, 1))

    gen(
      shell,
      Enum.join(firsts, " "),
      Map.new(seconds, fn {f, ss} -> {f, Enum.join(ss, " ")} end)
    )
  end

  defp gen(:bash, firsts, seconds) do
    cases = Enum.map_join(seconds, "", fn {f, ss} -> "      #{f}) opts=\"#{ss}\" ;;\n" end)

    """
    _herdr_live() {
      local opts
      if [ "$COMP_CWORD" = 1 ]; then
        opts="#{firsts}"
      else
        case ${COMP_WORDS[1]} in
    #{cases}    esac
      fi
      COMPREPLY=($(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}"))
    }
    complete -F _herdr_live herdr-live
    """
  end

  defp gen(:zsh, firsts, seconds) do
    cases = Enum.map_join(seconds, "", fn {f, ss} -> "      #{f}) compadd #{ss} ;;\n" end)

    """
    #compdef herdr-live
    _herdr_live() {
      if [ "$CURRENT" = 2 ]; then
        compadd #{firsts}
      else
        case $words[2] in
    #{cases}    esac
      fi
    }
    compdef _herdr_live herdr-live
    """
  end

  defp gen(:fish, firsts, seconds) do
    "complete -c herdr-live -f -n '__fish_use_subcommand' -a '#{firsts}'\n" <>
      Enum.map_join(seconds, "", fn {f, ss} ->
        "complete -c herdr-live -f -n '__fish_seen_subcommand_from #{f}; " <>
          "and not __fish_seen_subcommand_from #{ss}' -a '#{ss}'\n"
      end)
  end
end
