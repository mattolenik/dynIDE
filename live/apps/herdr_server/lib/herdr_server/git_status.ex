defmodule HerdrServer.GitStatus do
  @moduledoc """
  A directory's git branch and ahead/behind counts: `parse/1` reads `git status
  --porcelain=v2 --branch` headers (pure); `status/1` runs it through `Worktree.run/1`
  (same git lookup and env) and is nil when git is missing or `cwd` is not a repo.
  """

  alias HerdrServer.Worktree

  @type info :: %{branch: binary | nil, ahead: non_neg_integer, behind: non_neg_integer}

  @doc "Branch (nil when detached) and ahead/behind (0 without an upstream)."
  @spec parse(binary) :: info
  def parse(out) do
    out
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce(%{branch: nil, ahead: 0, behind: 0}, fn
      "# branch.head (detached)", acc -> acc
      "# branch.head " <> b, acc -> %{acc | branch: b}
      "# branch.ab " <> ab, acc -> ab(ab, acc)
      _, acc -> acc
    end)
  end

  defp ab(ab, acc) do
    case Regex.run(~r/^\+(\d+) -(\d+)$/, String.trim(ab)) do
      [_, a, b] -> %{acc | ahead: String.to_integer(a), behind: String.to_integer(b)}
      _ -> acc
    end
  end

  @doc "`parse/1` of `cwd`'s status, or nil when git fails there."
  @spec status(Path.t()) :: info | nil
  def status(cwd) do
    case Worktree.run(["-C", cwd, "status", "--porcelain=v2", "--branch", "--untracked-files=no"]) do
      {:ok, out} -> parse(out)
      {:error, _} -> nil
    end
  end
end
