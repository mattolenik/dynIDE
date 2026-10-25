defmodule HerdrServer.App.Workspaces.Label do
  @moduledoc """
  A workspace's automatic name from its root pane's cwd: the repo directory's basename
  when the cwd is inside a git checkout (a `.git` directory, or a `.git` file in a linked
  worktree, whose own directory names it), else the cwd's basename. No git process runs:
  only `File.stat/1` while walking up.
  """

  @spec auto(binary | nil) :: binary | nil
  def auto(cwd) when cwd in [nil, "", "/"], do: nil

  def auto(cwd) when is_binary(cwd) do
    dir = Path.expand(cwd)
    Path.basename(repo_root(dir) || dir)
  end

  def auto(_other), do: nil

  defp repo_root(dir) do
    case File.stat(Path.join(dir, ".git")) do
      {:ok, %{type: t}} when t in [:directory, :regular] -> dir
      _ -> if Path.dirname(dir) == dir, do: nil, else: repo_root(Path.dirname(dir))
    end
  end
end
